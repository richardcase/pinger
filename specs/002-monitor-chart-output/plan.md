# Implementation Plan: Monitor Realtime Chart Output

**Branch**: `002-monitor-chart-output` | **Date**: 2026-05-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-monitor-chart-output/spec.md`

## Summary

Give `pinger monitor` a second terminal output mode — a realtime, continuously-updating ASCII line chart of per-target RTT over time — selected with a new `--display log|chart` flag (default `log`). Remove the `--json` console flag from `monitor` (breaking CLI change). Both modes keep writing JSONL to disk unchanged; `report --json` is untouched.

Technical approach: introduce a small internal `reporter` interface in `internal/monitor` with two implementations — `logReporter` (reproduces today's text output verbatim) and `chartReporter` (maintains a per-target rolling buffer and redraws via `github.com/guptarohit/asciigraph` `PlotMany`). Failures render as `math.NaN()` gaps. Chart mode draws into the alternate screen buffer and restores the terminal on exit, then prints the existing text summary. TTY detection and terminal width come from `golang.org/x/term`.

## Technical Context

**Language/Version**: Go 1.26.2 (per `go.mod` / `.mise.toml`)

**Primary Dependencies**: existing — `spf13/cobra`, `spf13/viper`, `prometheus-community/pro-bing`. New — `github.com/guptarohit/asciigraph` (ASCII line charts), `golang.org/x/term` (TTY detection + terminal size).

**Storage**: append-only daily JSONL files (`pinger-YYYY-MM-DD.jsonl`) — unchanged by this feature.

**Testing**: `go test ./...` (unit, deterministic) + `go test -tags integration` (privileged ICMP); `testify` assertions; fake probers per existing `internal/monitor/monitor_test.go`.

**Target Platform**: Linux/macOS terminal (amd64/arm64), per GoReleaser targets.

**Project Type**: single-binary CLI.

**Performance Goals**: chart redraw is O(width × targets) per probe cycle (cycles are interval-driven, e.g. seconds); negligible vs probe latency. Honors constitution: <1ms probe overhead unaffected, <500ms startup.

**Constraints**: rolling buffer bounded to terminal width → stable memory under sustained operation (no unbounded growth). Chart requires an interactive TTY; non-TTY + chart errors out (FR-013). Max 10 targets (existing config cap) → max 10 series.

**Scale/Scope**: 1–10 targets; one chart series per target; rolling window = terminal columns.

## Constitution Check

*GATE: re-checked after design below. Result: PASS (one noted breaking change).*

- **I. Code Quality** — PASS. `reporter` interface has a single responsibility per impl; `--json` removal deletes its branches entirely (no dead code / no compatibility shim). Complexity (the interface) justified by two genuinely different output behaviors with different state, not speculation.
- **II. Testing Standards** — PASS. Tests written alongside impl. Determinism preserved: `chartReporter` renders to an injected `io.Writer` with an injected size function — **no test touches a real terminal or network**. `logReporter` covered by a golden test asserting byte-identical output to today (protects SC-005). Each acceptance scenario maps to a test (see Phase 1 / quickstart).
- **III. UX Consistency** — PASS **with required MAJOR version bump**. Removing `monitor --json` is a breaking user-facing change → next release MUST increment the major version (constitution III). The "output MUST be parseable" principle remains satisfied for monitor data via the always-on JSONL persistence (FR-010) and the unchanged `report --json` (FR-012); ephemeral console JSON is replaced by these durable channels. New `--display` flag defaults to `log` → existing invocations and config files are unaffected. Error messages for invalid `--display` and non-TTY include what failed + why + next step.
- **IV. Performance Requirements** — PASS. Bounded ring buffer (terminal-width sized) → stable memory. Redraw cost trivial and interval-gated. Probe dispatch concurrency unchanged.

No unjustified violations → proceed. The MAJOR version bump is an action item for release, recorded in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/002-monitor-chart-output/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── cli.md           # Phase 1 output — monitor command contract
├── checklists/
│   └── requirements.md  # from /speckit-specify
└── tasks.md             # /speckit-tasks output (not created here)
```

### Source Code (repository root)

```text
cmd/pinger/
└── main.go              # MODIFY: drop --json; add --display log|chart; validate; TTY gate for chart

internal/monitor/
├── monitor.go           # MODIFY: Options.Display replaces JSONOutput; runCycle/printFinalSummary delegate to reporter
├── reporter.go          # NEW: reporter interface + logReporter (verbatim text) + chartReporter (asciigraph)
├── monitor_test.go      # MODIFY: drop JSONOutput cases; keep fake-prober loop tests
└── reporter_test.go     # NEW: logReporter golden output; chartReporter NaN-gap + legend rendering; display resolution

internal/probe/          # unchanged (ProbeResult is the data source)
internal/store/          # unchanged (JSONL persistence identical in both modes)
internal/config/         # unchanged
internal/report/         # unchanged (report --json preserved)
```

**Structure Decision**: Single Go CLI project, existing layout retained. All new logic lands in `internal/monitor` (the package that already owns console output), isolated in a new `reporter.go` so `monitor.go`'s loop stays lean. No new top-level packages — the chart is an output concern of the monitor loop, not a separate subsystem.

## Complexity Tracking

| Item | Why Needed | Note |
|------|-----------|------|
| MAJOR version bump on release | Removing `monitor --json` is a breaking CLI change (Constitution III) | Not a code violation; a release-tagging action. Record in CHANGELOG / release notes. |
| New deps: `asciigraph`, `x/term` | No stdlib ASCII charting or TTY-size primitive | Both tiny, widely used, pure-Go; aligns with "minimal deps" ethos (no full TUI framework like bubbletea pulled in). |
