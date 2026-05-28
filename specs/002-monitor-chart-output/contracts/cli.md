# CLI Contract: `pinger monitor` (Realtime Chart Output)

**Branch**: `002-monitor-chart-output` | **Date**: 2026-05-28

Scope: changes to the `pinger monitor` command only. `report` and `version` are unchanged (see `001-periodic-ping-monitor/contracts/cli.md`). This is a **breaking change** (`--json` removed) → next release MUST bump the major version.

## `pinger monitor` — flags (after this feature)

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--duration` | string | (none) | Stop after this duration (Go duration string: `30s`, `5m`, `1h`) |
| `--output` | string | (auto) | Results **file** destination (daily JSONL in `data_dir` if empty) — **unchanged** |
| `--display` | string | `log` | Terminal output mode: `log` (per-cycle text lines) or `chart` (realtime RTT chart) — **NEW** |
| ~~`--json`~~ | — | — | **REMOVED** — supplying it is now an unknown-flag error |

Note: `--output` (results file) and `--display` (terminal mode) are independent and may be combined.

## Behaviour

### Common (both display modes)
- Reads config from `--config`. Exits 1 if missing/invalid.
- Checks raw-socket privilege; exits 1 if absent.
- Checks `data_dir` writable; exits 1 if not.
- Dispatches one goroutine per target each interval cycle; appends `ProbeResult` records to the JSONL file **identically regardless of `--display`** (FR-010).
- On `--duration` elapsed or SIGINT/SIGTERM: completes/abandons the in-flight cycle, flushes writes, prints the final per-target summary, exits 0.

### `--display log` (default)
Unchanged from today. Per cycle, one text line per target with at least one probe this run:

```
[2026-05-27T10:01:00Z] gateway     sent=5 errors=0 avg_rtt=1.23ms
[2026-05-27T10:01:00Z] dns-primary sent=5 errors=1 avg_rtt=2.10ms
```

Final summary (`TOTAL` lines + `monitor stopped`) is byte-identical to the pre-feature output (SC-005). Passing `--display log` explicitly behaves the same as omitting it.

### `--display chart`
- **Requires an interactive terminal.** If stdout is not a TTY → exits 1 before probing with a message pointing to `--display log` (FR-013).
- Switches to the alternate screen buffer, hides the cursor, and renders a single combined ASCII line chart: one colored, legend-labelled series per target, RTT (ms) on the Y-axis (auto-scaled), time advancing left→right.
- Redraws each probe cycle (FR-004). The visible window is sized to the terminal width; oldest points scroll off (rolling window, FR-007). Adapts to terminal resize.
- A failed/lost probe for a target leaves a **gap** in that target's line (no point), never a `0` (FR-006).
- On stop (Ctrl-C or `--duration`): leaves the alternate screen and restores the cursor (clean terminal, no artifacts — SC-004), **then** prints the same final text summary as log mode (FR-011).

Illustrative (rendering is terminal-dependent):

```
 12.00 ┤            ╭╮
  9.00 ┤      ╭─╮  ╭╯╰
  6.00 ┤╭╮ ╭──╯ ╰──╯
  3.00 ┼╯╰─╯
       gateway ── dns-primary ──
RTT (ms) over time
```

## Validation errors

| Condition | Result |
|-----------|--------|
| `--display` value not in {`log`,`chart`} | Exit 1: `error: invalid --display "<v>": must be "log" or "chart".` |
| `--display chart` with non-TTY stdout | Exit 1: `error: --display chart requires an interactive terminal. Use --display log when piping or redirecting output.` |
| `--json` supplied | Exit 1: cobra unknown-flag error (`unknown flag: --json`) |

All error text follows the project format: `error: <what failed>: <why>. <what to do next>.`

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Clean stop (duration elapsed, SIGINT, or SIGTERM) |
| 1 | Startup error: config invalid, no privilege, unwritable dir, invalid `--display`, `--display chart` without a TTY, or unknown flag |

## Examples

```bash
# Default log output (unchanged)
sudo pinger monitor --duration 1h

# Realtime chart in an interactive terminal
sudo pinger monitor --display chart

# Chart requested while piping → error, exit 1
sudo pinger monitor --display chart | tee out.txt

# --json no longer exists → unknown flag, exit 1
sudo pinger monitor --json
```
