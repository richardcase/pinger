# Quickstart: Monitor Realtime Chart Output

## What changed

`pinger monitor` now has two terminal display modes, selected with `--display`:

- `--display log` (default) — the existing per-cycle text lines. Unchanged.
- `--display chart` — a realtime ASCII line chart of each target's RTT over time.

The old `monitor --json` flag is **removed**. Structured data still lives in the daily JSONL files, and `pinger report --json` is unchanged.

## Try it

```bash
go build ./cmd/pinger

# Default text output (unchanged behavior)
sudo ./pinger monitor --duration 30s

# Realtime chart (needs an interactive terminal)
sudo ./pinger monitor --display chart

# Chart while redirecting → fails fast with guidance
sudo ./pinger monitor --display chart > out.txt   # exit 1

# Removed flag → unknown-flag error
sudo ./pinger monitor --json                       # exit 1
```

Press Ctrl-C to stop: the chart clears, the terminal is restored, and the final per-target summary prints.

## New dependencies

```bash
go get github.com/guptarohit/asciigraph
go get golang.org/x/term
```

## How it works (for implementers)

- `internal/monitor/reporter.go` defines a `reporter` interface with `logReporter` (verbatim text) and `chartReporter` (asciigraph `PlotMany`).
- `runCycle` builds `[]targetCycle` rows (it already computes sent/errors/avgMs) and calls `reporter.cycle`; `printFinalSummary` calls `reporter.final`.
- `chartReporter` keeps a per-target rolling buffer (NaN = failed cycle → line gap), reads terminal size via `golang.org/x/term`, and redraws each cycle into the alternate screen buffer.
- Flag handling in `cmd/pinger/main.go`: `--display` (default `log`) replaces `--json`; a pure `resolveDisplay(mode, isTTY)` validates the value and the TTY requirement.

## Verification — acceptance scenarios → tests

| Spec item | How to verify |
|-----------|---------------|
| FR-002 / SC-005 (log identical) | `reporter_test.go` golden test: `logReporter` output byte-identical to the old format, for cycle and final. |
| FR-003 / FR-005 (combined chart, per-target legend) | `chartReporter` test: render to a `bytes.Buffer` with fixed size; assert output contains each target legend and a line. |
| FR-006 / SC-003 (failure = gap) | Feed a cycle where a target failed; assert that series' buffer holds `NaN` at that index and no `0` is plotted. |
| FR-007 (rolling window) | Append > width points; assert buffer length capped to width and oldest dropped. |
| FR-008 / SC-006 (`--json` rejected) | CLI test: `monitor --json` → cobra unknown-flag error, non-zero. |
| FR-009 (invalid `--display`) | `resolveDisplay("graph", true)` → error naming valid values. |
| FR-013 (non-TTY + chart) | `resolveDisplay("chart", false)` → error pointing to `--display log`. |
| FR-011 / SC-004 (clean exit) | Integration: chart mode + `--duration` tiny + fake prober + injected writer; assert alt-screen leave sequence emitted, then final summary text present. |
| FR-010 (JSONL identical) | Existing store tests + run both modes; JSONL records unchanged. |

All unit tests run without a real terminal or network (injected `io.Writer` + size function + fake prober), per the constitution's determinism rule.

```bash
go test ./...
go test -tags integration ./...   # privileged ICMP path
golangci-lint run
```
