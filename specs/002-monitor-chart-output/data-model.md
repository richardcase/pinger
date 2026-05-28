# Data Model: Monitor Realtime Chart Output

This feature adds **no persisted entities** — the on-disk `ProbeResult` JSONL schema (`internal/store/record.go`) and `data_dir` layout are unchanged (FR-010). All new state is in-memory, scoped to a single `monitor` run. Entities below are runtime types.

## Existing (unchanged) — source data

### ProbeResult (`internal/store/record.go`)
| Field | Type | Notes |
|-------|------|-------|
| `Timestamp` | `time.Time` | UTC, RFC3339Nano on disk |
| `Target` | `string` | target label |
| `Success` | `bool` | true if a reply was received |
| `RTTMs` | `*float64` | round-trip ms; nil on failure |
| `FailReason` | `*string` | reason; nil on success |

The chart consumes the per-cycle aggregate the monitor loop already computes, not raw `ProbeResult`s directly.

## New runtime types (`internal/monitor`)

### displayMode (enum)
Represents the selected terminal output mode.
- Values: `log` (default), `chart`.
- Source: `--display` flag → validated by `resolveDisplay(mode string, isTTY bool)`.
- Validation rules:
  - Unknown value → error naming valid values `log`, `chart` (FR-009).
  - `chart` while `isTTY == false` → error pointing to `--display log` (FR-013).
- Replaces the removed `Options.JSONOutput bool`.

### targetCycle (per-cycle row)
The unit passed from the monitor loop to a `reporter` for one target in one cycle. Derived from the loop's existing `summary` aggregation.
| Field | Type | Meaning |
|-------|------|---------|
| `Label` | `string` | target label |
| `Sent` | `int` | probes attempted this run (cumulative, as today) |
| `Errors` | `int` | failures this run (cumulative, as today) |
| `AvgMs` | `float64` | cumulative average RTT in ms (0 when no successes) — used by `logReporter` |
| `CycleMs` | `*float64` | **this cycle's** RTT in ms; nil when the cycle failed — used by `chartReporter` (nil → `NaN` gap) |

> Note: `Sent/Errors/AvgMs` are cumulative across the run (`summary{sent,errors,totalRTT}`); `logReporter` prints them exactly as today. The chart plots **per-cycle** RTT, not the running average — `chartReporter` uses `CycleMs` (this cycle's `r.pr.RTTMs`, nil on failure → `NaN`). Captured per target during the collection loop in `runCycle`.

### chartSeries (per-target rolling buffer) — chartReporter state
One per target, keyed by label; ordered to match `cfg.Targets`.
| Field | Type | Meaning |
|-------|------|---------|
| `label` | `string` | series legend label |
| `points` | `[]float64` | recent RTT values; `math.NaN()` marks a failed cycle (FR-006) |

Lifecycle / rules:
- Append one point per probe cycle (FR-004).
- Bounded to the live terminal column count: when `len(points) > width`, drop oldest (FR-007 — rolling window, stable memory per Constitution IV).
- Width/height re-read from `x/term.GetSize` each redraw → adapts to terminal resize.
- Rendered together via `asciigraph.PlotMany([][]float64{...}, SeriesColors(...), SeriesLegends(labels...), Width(cols), Height(rows))`.

### reporter (interface)
Abstraction over the two output modes; implemented by `logReporter` and `chartReporter`.
- `cycle(ts time.Time, rows []targetCycle)` — emit one probe cycle's output.
- `final(ts time.Time, rows []targetCycle)` — emit the end-of-run summary (and, for chart, restore the terminal first).
- Both write to an injected `io.Writer`; `chartReporter` also holds an injected size function → deterministic tests.

## Relationships

```
cfg.Targets (1..10) ──drives──> chartSeries (one per target)
probe cycle ──aggregates──> []targetCycle ──cycle()──> reporter ──> io.Writer
                                            ──final()──> reporter ──> io.Writer
ProbeResult ──writer.Write──> JSONL file        (unchanged, both modes)
```
