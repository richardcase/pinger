package monitor

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os/signal"
	"syscall"
	"time"

	"github.com/richardcase/pinger/internal/config"
	"github.com/richardcase/pinger/internal/probe"
	"github.com/richardcase/pinger/internal/store"
)

// Options controls optional monitor behaviour.
type Options struct {
	Duration           time.Duration
	JSONOutput         bool
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
	runCycle(ctx, cfg, prober, writer, opts, summaries)

	for {
		select {
		case <-ctx.Done():
			printFinalSummary(cfg, opts, summaries)
			return nil
		case <-ticker.C:
			runCycle(ctx, cfg, prober, writer, opts, summaries)
		}
	}
}

// runCycle dispatches one goroutine per target, collects results concurrently,
// and abandons collection if ctx is cancelled.
func runCycle(ctx context.Context, cfg *config.Config, prober probe.Prober, writer *store.Writer, opts Options, summaries map[string]*summary) {
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

	collected := 0
	for collected < len(cfg.Targets) {
		select {
		case r := <-ch:
			s := summaries[r.target]
			s.sent++
			_ = writer.Write(r.pr)
			if r.pr.Success && r.pr.RTTMs != nil {
				s.totalRTT += time.Duration(*r.pr.RTTMs * float64(time.Millisecond))
			} else {
				s.errors++
			}
			collected++
		case <-ctx.Done():
			return // context cancelled — abandon pending probes
		}
	}

	ts := time.Now().UTC()
	for _, t := range cfg.Targets {
		s := summaries[t.Label]
		if s.sent == 0 {
			continue
		}
		var avgMs float64
		if s.sent > s.errors {
			avgMs = float64(s.totalRTT) / float64(time.Millisecond) / float64(s.sent-s.errors)
		}
		if opts.JSONOutput {
			line, _ := json.Marshal(map[string]interface{}{
				"timestamp":  ts.Format(time.RFC3339),
				"label":      t.Label,
				"sent":       s.sent,
				"errors":     s.errors,
				"avg_rtt_ms": avgMs,
			})
			fmt.Println(string(line))
		} else {
			fmt.Printf("[%s] %s sent=%d errors=%d avg_rtt=%.2fms\n",
				ts.Format(time.RFC3339), t.Label, s.sent, s.errors, avgMs)
		}
	}
}

func printFinalSummary(cfg *config.Config, opts Options, summaries map[string]*summary) {
	ts := time.Now().UTC()
	if opts.JSONOutput {
		type targetSummary struct {
			Label    string  `json:"label"`
			Sent     int     `json:"sent"`
			Errors   int     `json:"errors"`
			AvgRTTMs float64 `json:"avg_rtt_ms"`
		}
		targets := make([]targetSummary, 0, len(cfg.Targets))
		for _, t := range cfg.Targets {
			s := summaries[t.Label]
			var avgMs float64
			if s.sent > s.errors {
				avgMs = float64(s.totalRTT) / float64(time.Millisecond) / float64(s.sent-s.errors)
			}
			targets = append(targets, targetSummary{Label: t.Label, Sent: s.sent, Errors: s.errors, AvgRTTMs: avgMs})
		}
		line, _ := json.Marshal(map[string]interface{}{
			"timestamp": ts.Format(time.RFC3339),
			"event":     "summary",
			"targets":   targets,
		})
		fmt.Println(string(line))
		shutdown, _ := json.Marshal(map[string]interface{}{
			"timestamp": ts.Format(time.RFC3339),
			"event":     "shutdown",
		})
		fmt.Println(string(shutdown))
	} else {
		for _, t := range cfg.Targets {
			s := summaries[t.Label]
			var avgMs float64
			if s.sent > s.errors {
				avgMs = float64(s.totalRTT) / float64(time.Millisecond) / float64(s.sent-s.errors)
			}
			fmt.Printf("[%s] %s TOTAL sent=%d errors=%d avg_rtt=%.2fms\n",
				ts.Format(time.RFC3339), t.Label, s.sent, s.errors, avgMs)
		}
		fmt.Printf("[%s] monitor stopped\n", ts.Format(time.RFC3339))
	}
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
