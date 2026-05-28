package monitor

import (
	"bytes"
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/richardcase/pinger/internal/config"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func fixedSize(w, h int) sizeFunc { return func() (int, int) { return w, h } }

func cfgWithTargets(labels ...string) *config.Config {
	c := &config.Config{}
	for _, l := range labels {
		c.Targets = append(c.Targets, config.Target{Label: l, Address: "127.0.0.1"})
	}
	return c
}

func ms(v float64) *float64 { return &v }

// T014: logReporter output is byte-identical to the pre-feature text format.
func TestLogReporterGolden(t *testing.T) {
	ts := time.Date(2026, 5, 27, 10, 1, 0, 0, time.UTC)
	rows := []targetCycle{
		{Label: "gateway", Sent: 5, Errors: 0, AvgMs: 1.23},
		{Label: "dns-primary", Sent: 5, Errors: 1, AvgMs: 2.10},
	}

	var buf bytes.Buffer
	(&logReporter{w: &buf}).cycle(ts, rows)
	wantCycle := "[2026-05-27T10:01:00Z] gateway sent=5 errors=0 avg_rtt=1.23ms\n" +
		"[2026-05-27T10:01:00Z] dns-primary sent=5 errors=1 avg_rtt=2.10ms\n"
	assert.Equal(t, wantCycle, buf.String())

	buf.Reset()
	(&logReporter{w: &buf}).final(ts, rows)
	wantFinal := "[2026-05-27T10:01:00Z] gateway TOTAL sent=5 errors=0 avg_rtt=1.23ms\n" +
		"[2026-05-27T10:01:00Z] dns-primary TOTAL sent=5 errors=1 avg_rtt=2.10ms\n" +
		"[2026-05-27T10:01:00Z] monitor stopped\n"
	assert.Equal(t, wantFinal, buf.String())
}

// logReporter.cycle skips targets with zero probes this run (pre-feature behavior).
func TestLogReporterSkipsZeroSent(t *testing.T) {
	ts := time.Date(2026, 5, 27, 10, 1, 0, 0, time.UTC)
	var buf bytes.Buffer
	(&logReporter{w: &buf}).cycle(ts, []targetCycle{
		{Label: "live", Sent: 3, Errors: 0, AvgMs: 1.0},
		{Label: "quiet", Sent: 0, Errors: 0, AvgMs: 0},
	})
	out := buf.String()
	assert.Contains(t, out, "live")
	assert.NotContains(t, out, "quiet", "sent==0 target must be skipped per-cycle")
}

// T008: chartReporter renders a single combined chart with every target's legend label
// and a plotted line; the 10-target case keeps all legends distinct (SC-002).
func TestChartReporterRendersLegendsAndLine(t *testing.T) {
	cfg := cfgWithTargets("gateway", "dns-primary")
	var buf bytes.Buffer
	cr := newChartReporter(&buf, fixedSize(80, 24), cfg)
	cr.cycle(time.Now(), []targetCycle{
		{Label: "gateway", CycleMs: ms(1.5)},
		{Label: "dns-primary", CycleMs: ms(3.0)},
	})

	out := buf.String()
	assert.Contains(t, out, "gateway")
	assert.Contains(t, out, "dns-primary")
	assert.True(t, strings.ContainsAny(out, "┤┼│╮╯╭╰─"), "expected a plotted line, got:\n%s", out)

	t.Run("ten targets", func(t *testing.T) {
		labels := make([]string, 10)
		for i := range labels {
			labels[i] = fmt.Sprintf("tgt-%02d", i)
		}
		cfg10 := cfgWithTargets(labels...)
		var buf10 bytes.Buffer
		cr10 := newChartReporter(&buf10, fixedSize(120, 40), cfg10)
		rows := make([]targetCycle, len(labels))
		for i, l := range labels {
			rows[i] = targetCycle{Label: l, CycleMs: ms(float64(i) + 1)}
		}
		cr10.cycle(time.Now(), rows)
		out10 := buf10.String()
		for _, l := range labels {
			assert.Contains(t, out10, l, "all 10 legends must render")
		}
	})
}

// T009: a failed cycle stores math.NaN() (never 0), and the buffer is a rolling window
// capped to terminal width (oldest dropped).
func TestChartReporterFailureAndRollingWindow(t *testing.T) {
	t.Run("failure stores NaN not zero", func(t *testing.T) {
		cfg := cfgWithTargets("gw")
		cr := newChartReporter(&bytes.Buffer{}, fixedSize(40, 20), cfg)
		cr.cycle(time.Now(), []targetCycle{{Label: "gw", CycleMs: nil}})
		pts := cr.series[0].points
		require.Len(t, pts, 1)
		assert.True(t, math.IsNaN(pts[0]), "failed cycle must store NaN")
		assert.NotEqual(t, 0.0, pts[0], "failure must never be plotted as 0")
	})

	t.Run("rolling window caps to width", func(t *testing.T) {
		width := 5
		cfg := cfgWithTargets("gw")
		cr := newChartReporter(&bytes.Buffer{}, fixedSize(width, 20), cfg)
		for v := 1; v <= 8; v++ {
			cr.cycle(time.Now(), []targetCycle{{Label: "gw", CycleMs: ms(float64(v))}})
		}
		pts := cr.series[0].points
		assert.Len(t, pts, width, "buffer capped to terminal width")
		assert.Equal(t, 4.0, pts[0], "oldest points dropped; window holds 4..8")
		assert.Equal(t, 8.0, pts[len(pts)-1])
	})
}

// T021: a size change between redraws adapts the window without panicking.
func TestChartReporterHandlesResize(t *testing.T) {
	w := 5
	cfg := cfgWithTargets("gw")
	cr := newChartReporter(&bytes.Buffer{}, func() (int, int) { return w, 20 }, cfg)

	assert.NotPanics(t, func() {
		for v := 1; v <= 6; v++ {
			cr.cycle(time.Now(), []targetCycle{{Label: "gw", CycleMs: ms(float64(v))}})
		}
		w = 9 // terminal widened
		for v := 7; v <= 14; v++ {
			cr.cycle(time.Now(), []targetCycle{{Label: "gw", CycleMs: ms(float64(v))}})
		}
	})
	assert.LessOrEqual(t, len(cr.series[0].points), 9, "window must respect the latest width")
}

// T018: resolveDisplay validates the flag value and the TTY requirement.
func TestResolveDisplay(t *testing.T) {
	tests := []struct {
		name    string
		mode    string
		isTTY   bool
		want    DisplayMode
		wantErr bool
		errHas  string
	}{
		{name: "log on tty", mode: "log", isTTY: true, want: DisplayLog},
		{name: "log without tty", mode: "log", isTTY: false, want: DisplayLog},
		{name: "chart on tty", mode: "chart", isTTY: true, want: DisplayChart},
		{name: "unknown value", mode: "graph", isTTY: true, wantErr: true, errHas: `must be "log" or "chart"`},
		{name: "chart without tty", mode: "chart", isTTY: false, wantErr: true, errHas: "--display log"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ResolveDisplay(tc.mode, tc.isTTY)
			if tc.wantErr {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tc.errHas)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
		})
	}
}
