# Feature Specification: Monitor Realtime Chart Output

**Feature Branch**: `002-monitor-chart-output`

**Created**: 2026-05-28

**Status**: Draft

**Input**: User description: "Update the CLI so when running 'monitor' there is an option to display a graph instead of the log lines. The graph should show the ping response time for the targets over time. The '--json' option should also be removed. This means we will end up with 2 options for terminal output: 1) current log lines, 2) realtime chart"

## Clarifications

### Session 2026-05-28

- Q: When `--display chart` is requested but stdout is not an interactive terminal (piped/redirected), what should monitor do? → A: Error with guidance — fail fast, point to `--display log`, exit non-zero, do not start probing.
- Q: How should a failed probe / packet loss appear on the chart? → A: Gap in the line — no point plotted for that cycle (never rendered as a numeric RTT).
- Q: How much history should the rolling chart window show? → A: Fit to terminal width — show as many recent points as columns allow; oldest scroll off.
- Q: What is the mode flag named, given `--output` is already the results-file flag? → A: `--display log|chart` (default `log`); the existing `--output` file flag is unchanged.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Watch RTT live as a chart (Priority: P1)

An operator monitoring connectivity runs the monitor in chart mode and watches a continuously-updating line chart of each target's ping response time over time, instead of scrolling log lines.

**Why this priority**: This is the feature's reason for existing — a visual, at-a-glance read of latency trends and spikes across targets that log lines can't convey.

**Independent Test**: Run `pinger monitor --display chart` against configured targets; confirm a live chart appears, plots a point per target per probe cycle, and updates over time.

**Acceptance Scenarios**:

1. **Given** valid config with N targets (1–10), **When** the user runs `monitor --display chart`, **Then** a single combined chart renders with one distinct, labelled series per target plotting RTT (ms) against time.
2. **Given** the chart is running, **When** each probe cycle completes, **Then** the chart updates to include the newest RTT values within that probe interval.
3. **Given** the chart is running, **When** the user presses Ctrl-C (or `--duration` elapses), **Then** the chart closes, the terminal is restored to a clean usable state, and the final per-target summary is printed.

---

### User Story 2 - Keep existing log-line output as default (Priority: P2)

An operator (or a script/service) runs the monitor exactly as before and gets the current per-cycle log lines, with no behavior change.

**Why this priority**: Existing usage and any automation around log output must not break. The chart is additive; log lines remain the default.

**Independent Test**: Run `pinger monitor` with no output flag (and `--display log`); confirm output matches the current log-line format and the final summary is unchanged.

**Acceptance Scenarios**:

1. **Given** no output flag, **When** the user runs `monitor`, **Then** output is the current log-line format (`[ts] label sent=N errors=N avg_rtt=Xms`) and final summary, identical to today.
2. **Given** `--display log` is passed explicitly, **When** the user runs `monitor`, **Then** behavior is identical to passing no flag.

---

### User Story 3 - Retire `--json` from monitor (Priority: P3)

The `--json` per-cycle/summary output is removed from `monitor`; the only output modes are log lines and chart.

**Why this priority**: Required by the request and simplifies the command surface, but lower urgency than delivering the chart and preserving the default.

**Independent Test**: Run `pinger monitor --json`; confirm it is rejected with a clear unknown-flag error.

**Acceptance Scenarios**:

1. **Given** `--json` is passed to `monitor`, **When** the command runs, **Then** it fails fast with a clear "unknown flag" error and does not start probing.
2. **Given** the `report` command, **When** `report --json` is used, **Then** it still emits JSON as before (out of scope for removal).

---

### Edge Cases

- **Non-interactive stdout**: chart requested while stdout is not a TTY (piped/redirected) → fail fast with a clear message pointing to `--display log`, exit non-zero, do not start probing.
- **Probe failure / packet loss**: a target that times out or fails DNS in a cycle → leaves a gap in that target's line (no point plotted for the cycle), never plotted as `0 ms`.
- **Many targets**: up to 10 simultaneous series remain visually distinguishable (legend + distinct colors; palette must cover all 10).
- **Terminal resize** while the chart is running → chart adapts without corrupting the display.
- **No data yet**: before the first cycle completes, the chart shows an empty/initialising state rather than erroring.
- **`--duration` in chart mode**: chart closes cleanly on duration expiry, then the final summary prints.
- **Invalid `--display` value** (e.g. `--display graph`) → clear error listing the valid values (`log`, `chart`).
- **Long-running session**: chart shows a bounded rolling window (sized to terminal width) so memory and rendering stay stable; oldest points scroll off.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The `monitor` command MUST provide a `--display` flag accepting `log` or `chart`, defaulting to `log`. (The existing `--output` flag, which sets the results-file destination, is unchanged.)
- **FR-002**: With `--display log` (or no flag), monitor MUST preserve the existing per-cycle log-line output and final summary unchanged.
- **FR-003**: With `--display chart`, monitor MUST render a single combined, continuously-updating chart plotting RTT (milliseconds) over time for all configured targets, one distinct series per target.
- **FR-004**: The chart MUST update as each probe cycle produces new results.
- **FR-005**: Each target's series MUST be identifiable by a distinct color and a legend label. (The chosen renderer differentiates series by color + legend, not by dashed/styled lines.)
- **FR-006**: Probe failures / packet loss MUST leave a gap in the affected target's line (no point plotted for that cycle) and MUST NOT be plotted as a numeric RTT (e.g. not as `0`).
- **FR-007**: The vertical (RTT) axis MUST scale to the observed values so all series remain readable; the chart MUST show a bounded rolling window sized to the terminal width, with the oldest points scrolling off as new ones arrive.
- **FR-008**: The `monitor` command MUST NOT accept `--json`; supplying it MUST produce a clear error and abort before probing.
- **FR-009**: An invalid `--display` value MUST produce a clear error naming the valid values.
- **FR-010**: JSONL persistence to the data directory MUST behave identically in both output modes (output mode affects terminal display only).
- **FR-011**: Chart mode MUST honour `--duration` and SIGINT/SIGTERM: on stop it MUST restore the terminal to a clean state and then print the final per-target summary.
- **FR-012**: The `report` command's `--json` flag MUST remain unchanged (explicitly out of scope for removal).
- **FR-013**: When `--display chart` is requested and stdout is not an interactive terminal, monitor MUST fail fast with a clear message pointing to `--display log`, exit non-zero, and not start probing.

### Key Entities *(include if feature involves data)*

- **Target series**: a per-target, time-ordered sequence of (timestamp, RTT-ms | failure) points driving one chart line; identified by the target's label.
- **Probe result**: the existing per-probe outcome (timestamp, target, success, RTT-ms, failure reason) — the shared data source for both output modes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator switches from log to chart output with a single flag and no config-file change, and sees the first plotted point within one probe interval.
- **SC-002**: With the maximum 10 targets configured, every series is individually identifiable in the chart.
- **SC-003**: 100% of probe failures are visually distinguishable from successful RTT values (no failure is shown as a valid latency).
- **SC-004**: Every exit from chart mode (Ctrl-C or duration expiry) leaves the terminal clean and usable with no residual rendering artifacts.
- **SC-005**: Default and `--display log` runs produce output identical to the pre-feature behavior (existing log format and final summary preserved).
- **SC-006**: `monitor --json` is rejected with a clear error 100% of the time (never silently accepted or ignored).

## Assumptions

- Chart mode targets an interactive terminal; if stdout is not a TTY, monitor errors with guidance to use `--display log` (see FR-013).
- The chart shows a rolling window of recent points sized to the terminal width (not unbounded history) so it fits the terminal and stays performant over long sessions.
- RTT is plotted in milliseconds; the time axis advances with probe cycles.
- JSONL persistence, `data_dir`, the `--output` file destination, and `--duration` semantics are otherwise unchanged.
- The `report` command is untouched by this feature.
- The specific chart/TUI library and rendering implementation are deferred to `/speckit-plan`; this spec is implementation-agnostic.
