package monitor

import (
	"fmt"
	"io"
	"math"
	"time"

	"github.com/guptarohit/asciigraph"
	"github.com/richardcase/pinger/internal/config"
)

// DisplayMode selects the monitor's terminal output style.
type DisplayMode int

const (
	// DisplayLog is the default per-cycle text output.
	DisplayLog DisplayMode = iota
	// DisplayChart is the realtime ASCII RTT chart.
	DisplayChart
)

// ResolveDisplay validates a --display flag value against TTY availability.
// Unknown values and a non-TTY chart request both yield an actionable error.
func ResolveDisplay(mode string, isTTY bool) (DisplayMode, error) {
	switch mode {
	case "log":
		return DisplayLog, nil
	case "chart":
		if !isTTY {
			return DisplayLog, fmt.Errorf("error: --display chart requires an interactive terminal. Use --display log when piping or redirecting output.")
		}
		return DisplayChart, nil
	default:
		return DisplayLog, fmt.Errorf("error: invalid --display %q: must be \"log\" or \"chart\".", mode)
	}
}

// targetCycle is one target's data for a single probe cycle, handed to a reporter.
// Sent/Errors/AvgMs are cumulative across the run (used by logReporter); CycleMs is
// this cycle's RTT, nil on failure (used by chartReporter as a NaN gap).
type targetCycle struct {
	Label   string
	Sent    int
	Errors  int
	AvgMs   float64
	CycleMs *float64
}

// reporter renders monitor output for one probe cycle and the final summary.
type reporter interface {
	cycle(ts time.Time, rows []targetCycle)
	final(ts time.Time, rows []targetCycle)
}

// logReporter reproduces the original per-cycle text output verbatim.
type logReporter struct {
	w io.Writer
}

func (r *logReporter) cycle(ts time.Time, rows []targetCycle) {
	for _, row := range rows {
		if row.Sent == 0 {
			continue
		}
		fmt.Fprintf(r.w, "[%s] %s sent=%d errors=%d avg_rtt=%.2fms\n",
			ts.Format(time.RFC3339), row.Label, row.Sent, row.Errors, row.AvgMs)
	}
}

func (r *logReporter) final(ts time.Time, rows []targetCycle) {
	for _, row := range rows {
		fmt.Fprintf(r.w, "[%s] %s TOTAL sent=%d errors=%d avg_rtt=%.2fms\n",
			ts.Format(time.RFC3339), row.Label, row.Sent, row.Errors, row.AvgMs)
	}
	fmt.Fprintf(r.w, "[%s] monitor stopped\n", ts.Format(time.RFC3339))
}

// Terminal control sequences for the alternate screen buffer and cursor.
const (
	enterAltScreen = "\x1b[?1049h"
	leaveAltScreen = "\x1b[?1049l"
	hideCursor     = "\x1b[?25l"
	showCursor     = "\x1b[?25h"
	clearAndHome   = "\x1b[H\x1b[2J"
)

// chartPalette gives each target a visually distinct colored line. It holds ≥10
// distinct colors so all 10 max targets stay distinguishable; cycled if exceeded.
var chartPalette = []asciigraph.AnsiColor{
	asciigraph.Red, asciigraph.Green, asciigraph.Blue, asciigraph.Yellow,
	asciigraph.Cyan, asciigraph.Magenta, asciigraph.Orange, asciigraph.Purple,
	asciigraph.SpringGreen, asciigraph.DodgerBlue, asciigraph.HotPink, asciigraph.Gold,
}

// sizeFunc reports the current terminal width and height in cells.
type sizeFunc func() (width, height int)

// chartSeries is one target's rolling RTT buffer; math.NaN() marks a failed cycle.
type chartSeries struct {
	label  string
	points []float64
}

// chartReporter maintains per-target rolling buffers and redraws a combined
// asciigraph plot each cycle into the alternate screen buffer.
type chartReporter struct {
	w       io.Writer
	size    sizeFunc
	series  []*chartSeries
	index   map[string]int
	started bool
}

func newChartReporter(w io.Writer, size sizeFunc, cfg *config.Config) *chartReporter {
	cr := &chartReporter{w: w, size: size, index: make(map[string]int, len(cfg.Targets))}
	for i, t := range cfg.Targets {
		cr.series = append(cr.series, &chartSeries{label: t.Label})
		cr.index[t.Label] = i
	}
	return cr
}

func (r *chartReporter) cycle(_ time.Time, rows []targetCycle) {
	if !r.started {
		fmt.Fprint(r.w, enterAltScreen+hideCursor)
		r.started = true
	}
	width, height := r.size()
	for _, row := range rows {
		i, ok := r.index[row.Label]
		if !ok {
			continue
		}
		v := math.NaN()
		if row.CycleMs != nil {
			v = *row.CycleMs
		}
		s := r.series[i]
		s.points = append(s.points, v)
		if width > 0 && len(s.points) > width {
			s.points = s.points[len(s.points)-width:]
		}
	}
	r.render(width, height)
}

func (r *chartReporter) render(width, height int) {
	data := make([][]float64, len(r.series))
	legends := make([]string, len(r.series))
	colors := make([]asciigraph.AnsiColor, len(r.series))
	for i, s := range r.series {
		data[i] = s.points
		legends[i] = s.label
		colors[i] = chartPalette[i%len(chartPalette)]
	}

	plotWidth := width - 10
	if plotWidth < 10 {
		plotWidth = 10
	}
	plotHeight := height - 4
	if plotHeight < 3 {
		plotHeight = 3
	}

	// asciigraph derives the Y-axis from min/max; with zero finite points it would
	// divide by an infinite interval and produce a NaN row count. Skip until real data.
	if !anyFinite(data) {
		fmt.Fprint(r.w, clearAndHome)
		fmt.Fprintln(r.w, "RTT (ms) over time — waiting for data…")
		return
	}

	graph := asciigraph.PlotMany(data,
		asciigraph.Width(plotWidth),
		asciigraph.Height(plotHeight),
		asciigraph.SeriesColors(colors...),
		asciigraph.SeriesLegends(legends...),
		asciigraph.Caption("RTT (ms) over time"),
	)
	fmt.Fprint(r.w, clearAndHome)
	fmt.Fprintln(r.w, graph)
}

func anyFinite(data [][]float64) bool {
	for _, series := range data {
		for _, v := range series {
			if !math.IsNaN(v) {
				return true
			}
		}
	}
	return false
}

func (r *chartReporter) final(ts time.Time, rows []targetCycle) {
	if r.started {
		fmt.Fprint(r.w, leaveAltScreen+showCursor)
	}
	(&logReporter{w: r.w}).final(ts, rows)
}
