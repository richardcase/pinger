package monitor

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/richardcase/pinger/internal/config"
	"github.com/richardcase/pinger/internal/probe"
	"github.com/richardcase/pinger/internal/store"
	"golang.org/x/term"
)

// Options controls optional monitor behaviour.
type Options struct {
	Duration           time.Duration
	Display            DisplayMode
	SkipPrivilegeCheck bool   // for unit tests
	OutputFile         string // empty = autogenerate daily file in data_dir
}

type probeResult struct {
	target string
	pr     store.ProbeResult
}

type summary struct {
	sent     int
	errors   int
	totalRTT time.Duration
}

// Run executes the monitor loop until duration elapses, or SIGINT/SIGTERM arrives.
func Run(cfg *config.Config, prober probe.Prober, opts Options) error {
	return run(cfg, prober, opts, os.Stdout, termSize)
}

// termSize returns the live terminal dimensions, falling back to 80x24.
func termSize() (int, int) {
	w, h, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil || w <= 0 || h <= 0 {
		return 80, 24
	}
	return w, h
}

// run is the testable core: the console writer and terminal-size source are injected
// so unit tests never touch a real terminal.
func run(cfg *config.Config, prober probe.Prober, opts Options, out io.Writer, size sizeFunc) error {
	if !opts.SkipPrivilegeCheck {
		if err := checkPrivilege(); err != nil {
			return err
		}
	}
	if err := store.IsWritable(cfg.DataDir); err != nil {
		return err
	}

	writer, err := store.NewWriter(cfg.DataDir, opts.OutputFile)
	if err != nil {
		return fmt.Errorf("error: create writer: %w", err)
	}
	defer writer.Close()

	var rep reporter
	if opts.Display == DisplayChart {
		rep = newChartReporter(out, size, cfg)
	} else {
		rep = &logReporter{w: out}
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if opts.Duration > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, opts.Duration)
		defer cancel()
	}

	ticker := time.NewTicker(cfg.Interval)
	defer ticker.Stop()

	summaries := make(map[string]*summary, len(cfg.Targets))
	for _, t := range cfg.Targets {
		summaries[t.Label] = &summary{}
	}

	// Prime first cycle immediately.
	runCycle(ctx, cfg, prober, writer, rep, summaries)

	for {
		select {
		case <-ctx.Done():
			printFinalSummary(cfg, rep, summaries)
			return nil
		case <-ticker.C:
			runCycle(ctx, cfg, prober, writer, rep, summaries)
		}
	}
}

// runCycle dispatches one goroutine per target, collects results concurrently,
// and abandons collection if ctx is cancelled.
func runCycle(ctx context.Context, cfg *config.Config, prober probe.Prober, writer *store.Writer, rep reporter, summaries map[string]*summary) {
	ch := make(chan probeResult, len(cfg.Targets))

	for _, t := range cfg.Targets {
		t := t
		timeout := cfg.Timeout
		if t.Timeout != nil {
			timeout = *t.Timeout
		}
		go func() {
			pr := prober.Probe(t.Address, timeout)
			pr.Target = t.Label
			ch <- probeResult{target: t.Label, pr: pr}
		}()
	}

	cycleRTT := make(map[string]*float64, len(cfg.Targets))
	collected := 0
	for collected < len(cfg.Targets) {
		select {
		case r := <-ch:
			s := summaries[r.target]
			s.sent++
			_ = writer.Write(r.pr)
			if r.pr.Success && r.pr.RTTMs != nil {
				s.totalRTT += time.Duration(*r.pr.RTTMs * float64(time.Millisecond))
				cycleRTT[r.target] = r.pr.RTTMs
			} else {
				s.errors++
			}
			collected++
		case <-ctx.Done():
			return // context cancelled — abandon pending probes
		}
	}

	ts := time.Now().UTC()
	rep.cycle(ts, buildRows(cfg, summaries, cycleRTT))
}

// buildRows assembles per-target rows in config order. cycleRTT carries this cycle's
// RTT per target (nil/absent on failure); pass nil for the final summary.
func buildRows(cfg *config.Config, summaries map[string]*summary, cycleRTT map[string]*float64) []targetCycle {
	rows := make([]targetCycle, 0, len(cfg.Targets))
	for _, t := range cfg.Targets {
		s := summaries[t.Label]
		var avgMs float64
		if s.sent > s.errors {
			avgMs = float64(s.totalRTT) / float64(time.Millisecond) / float64(s.sent-s.errors)
		}
		rows = append(rows, targetCycle{
			Label:   t.Label,
			Sent:    s.sent,
			Errors:  s.errors,
			AvgMs:   avgMs,
			CycleMs: cycleRTT[t.Label],
		})
	}
	return rows
}

func printFinalSummary(cfg *config.Config, rep reporter, summaries map[string]*summary) {
	ts := time.Now().UTC()
	rep.final(ts, buildRows(cfg, summaries, nil))
}

// checkPrivilege verifies raw socket access.
func checkPrivilege() error {
	conn, err := net.ListenPacket("ip4:icmp", "")
	if err != nil {
		return fmt.Errorf("error: raw socket unavailable: %s. Run as root or grant CAP_NET_RAW.", err.Error())
	}
	conn.Close()
	return nil
}
