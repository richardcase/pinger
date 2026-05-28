# Research: Monitor Realtime Chart Output

Phase 0 — resolve the open technical unknown (how to render a realtime multi-series RTT chart in the terminal) and confirm supporting primitives. The spec deferred the charting library to planning; everything else was resolved during `/speckit-clarify`.

## Decision 1 — Charting library: `github.com/guptarohit/asciigraph`

**Decision**: Use `asciigraph` to render the chart; redraw the full plot once per probe cycle.

**Rationale**:
- Pure-Go, single small dependency. No cgo, no full TUI runtime (bubbletea/tcell), matching the repo's existing minimalist style (plain `fmt`, hand-rolled formatters) and the constitution's code-quality/perf principles.
- `PlotMany([][]float64, ...Option)` renders multiple series on one combined chart → satisfies the chosen "single combined chart" layout (FR-003).
- `SeriesColors(...)` + `SeriesLegends(...)` give each target a distinct colored line and a labelled legend → FR-005 (visually distinguishable + identifiable).
- A series value of `math.NaN()` renders as a **gap** in that line (confirmed in the library's "missing data" example) → exactly the failure representation chosen in clarify (FR-006); failures are never plotted as `0`.
- `Width(n)` / `Height(n)` size the plot; `Width` set from the live terminal column count gives the "fit terminal width" rolling window (FR-007). Y-axis auto-scales to the data by default (FR-007).
- `Caption(...)` and `Precision(...)` available for axis/units polish.

**Alternatives considered**:
- `NimbleMarkets/ntcharts` (bubbletea time-series) — full TUI; pulls bubbletea + lipgloss + tcell. Overkill for a single redrawing chart; heavier test surface; conflicts with minimal-deps ethos.
- `gizak/termui` — tcell-based widget framework; same heaviness objection.
- Hand-rolled ASCII plotting — reinvents asciigraph; more code to test for no benefit.

**Key API surface used**:
```go
asciigraph.PlotMany(series, // [][]float64, one slice per target, NaN = gap
    asciigraph.Width(cols),
    asciigraph.Height(rows),
    asciigraph.SeriesColors(colors...),   // len == len(series)
    asciigraph.SeriesLegends(labels...),  // target labels
    asciigraph.Caption("RTT (ms) over time"),
)
```

## Decision 2 — TTY detection + terminal size: `golang.org/x/term`

**Decision**: Use `golang.org/x/term` for both the non-TTY guard and the chart width.

**Rationale**:
- `term.IsTerminal(int(os.Stdout.Fd()))` → the FR-013 guard: if `--display chart` and stdout is not a TTY, fail fast.
- `term.GetSize(int(os.Stdout.Fd())) (w, h, err)` → terminal columns/rows for the rolling-window width and chart height; re-queried each redraw so a terminal resize is picked up automatically (resize edge case).
- Maintained under `golang.org/x`, tiny, pure-Go, no transitive bloat (the repo already vendors `golang.org/x/net` and `x/sys`).

**Alternatives considered**:
- `mattn/go-isatty` — only does the boolean check, still need a size source. `x/term` covers both → one dep instead of two.
- Raw `ioctl` / unix syscalls — non-portable, more code.

## Decision 3 — Redraw + terminal restore strategy

**Decision**: On entering chart mode, switch to the **alternate screen buffer** and hide the cursor; redraw the full `PlotMany` output each probe cycle (clear + reprint); on stop, leave the alternate screen, show the cursor, then print the existing text summary.

**Rationale**:
- Alt-screen (`ESC [?1049h` / `ESC [?1049l`) guarantees the terminal is restored to its prior contents with no residual artifacts on exit → FR-011 / SC-004, for both Ctrl-C and `--duration` expiry (both already funnel through `ctx.Done()`).
- Full redraw per cycle is simple and correct; cycle cadence (seconds+) makes flicker/cost a non-issue. No need for asciigraph's built-in realtime/fps streaming mode (designed for stdin pipes).
- Printing the final summary **after** restoring the screen keeps the post-run summary in the user's normal scrollback, consistent with log mode.

**Alternatives considered**:
- In-place redraw on the main screen (cursor-home + clear-to-end) — leaves the chart in scrollback and risks artifacts on resize; alt-screen is cleaner.
- asciigraph realtime mode — geared to its CLI/stdin, not an embedded library redraw loop.

## Decision 4 — Architecture: `reporter` interface in `internal/monitor`

**Decision**: Replace the inline `if opts.JSONOutput {...} else {...}` console branches with a `reporter` interface; `runCycle` builds per-target rows and calls `reporter.cycle(...)`, `printFinalSummary` calls `reporter.final(...)`. Two impls: `logReporter`, `chartReporter`.

**Rationale**:
- Two output modes with **different state** (chart needs per-target rolling buffers; log is stateless) is a real polymorphism need, not speculative abstraction → satisfies Constitution I.
- `logReporter` calls the **exact** existing `fmt.Printf` format strings → protects SC-005 (byte-identical log output) and is locked by a golden test.
- Both impls write to an injected `io.Writer`, and `chartReporter` takes an injected size function → deterministic, terminal-free unit tests (Constitution II).
- Per-cycle data point per target is **this cycle's** RTT (`r.pr.RTTMs`), captured during collection into `targetCycle.CycleMs`: success → `CycleMs`; failure → `NaN` (gap). NOT the cumulative `AvgMs` running average (which stays for `logReporter`).

**Alternatives considered**:
- Keep inline branching and add a third chart branch — bloats the loop with stateful buffer management; hard to test in isolation.
- Separate `internal/chart` package — unnecessary; the chart is an output concern of the monitor loop and shares its row data.

## Decision 5 — Flag design & display resolution

**Decision**: `monitor` gains `--display` (string, default `log`, values `log|chart`); `--json` is removed. A pure helper `resolveDisplay(mode string, isTTY bool) (displayMode, error)` centralizes validation: rejects unknown values (FR-009) and rejects `chart` when `!isTTY` (FR-013). The existing `--output` (results-file) and `--duration` flags are unchanged.

**Rationale**:
- `--output` is already taken by the results-file destination (clarified with the user) → mode flag is `--display`.
- A pure resolver function is trivially unit-testable for all three branches (valid log / valid chart / invalid / non-TTY) without a real terminal.
- Removing `--json` lets cobra emit its standard "unknown flag" error for `monitor --json` → FR-008 / SC-006 for free.

**Alternatives considered**:
- Boolean `--chart` — user chose an explicit enum for extensibility.
- Renaming `--output`→`--output-file` to free `--output` — adds a second breaking change for no benefit.

## Resolved unknowns summary

| Unknown | Resolution |
|---------|-----------|
| Charting library | `guptarohit/asciigraph` `PlotMany` |
| Multi-target on one chart | one series per target, `SeriesColors` + `SeriesLegends` |
| Failure rendering | `math.NaN()` → line gap |
| Rolling window | `Width` = live terminal columns (`x/term`) |
| TTY detect / non-TTY guard | `x/term.IsTerminal` |
| Clean exit / no artifacts | alternate screen buffer + cursor restore |
| Output-mode flag name | `--display log|chart`, default `log` |
| Keep log output identical | dedicated `logReporter` + golden test |
