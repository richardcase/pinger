# Feature Specification: Periodic Ping Monitor

**Feature Branch**: `001-periodic-ping-monitor`

**Created**: 2026-05-27

**Status**: Draft

**Input**: User description: "Create a CLI utility that will run ping against a set of targets on a periodic basis, the results of the ping will be saved to disk so that the data (i.e. the connectivity) can be mapped over time. Failures, response time etc will need to be saved"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Monitor Targets Over Time (Priority: P1)

An operator configures a list of network targets (hostnames or IP addresses) and starts the monitor.
The tool probes each target at a regular interval and records each result to disk. After running for
some period, the operator can inspect the saved data to see which targets were reachable, when they
were unreachable, and what the response times looked like over time.

**Why this priority**: This is the core value of the tool. Without continuous probing and persistent
storage, nothing else is meaningful.

**Independent Test**: Configure two targets, run for 60 seconds, stop, verify a data file exists
containing timestamped records for each target including response time and success/failure status.

**Acceptance Scenarios**:

1. **Given** a config file listing two targets and a 10-second interval, **When** the monitor runs
   for 30 seconds, **Then** at least 3 probe records per target are saved to disk, each containing a
   timestamp, target identifier, and response time or failure reason.
2. **Given** a target that is unreachable, **When** a probe attempt times out, **Then** a failure
   record is saved with a timestamp and a failure indicator; the monitor continues probing other
   targets without stopping.
3. **Given** an existing data file from a previous run, **When** the monitor is started again,
   **Then** new records are appended to the existing file rather than overwriting prior history.
4. **Given** the monitor is started with `--duration 1m`, **When** 60 seconds elapses, **Then**
   the monitor completes the current probe cycle, writes all results, prints a final summary,
   and exits with zero status without requiring manual intervention.
5. **Given** the monitor is running without a duration, **When** the operator presses Ctrl-C,
   **Then** the monitor finishes any in-flight writes, prints a final summary, and exits cleanly.

---

### User Story 2 - View Connectivity History (Priority: P2)

An operator queries the saved data to review connectivity history for one or more targets across a
time window, seeing a summary of uptime, failure count, and response time distribution.

**Why this priority**: Persistent data has no value unless it can be queried. This closes the loop
between collection and insight.

**Independent Test**: Given a pre-populated data file with known records, run the read/report command
and verify the output lists correct uptime percentage, failure count, and min/max/avg response times.

**Acceptance Scenarios**:

1. **Given** a data file containing records for multiple targets, **When** the operator requests a
   summary for a specific target, **Then** the output shows total probes, successful probes, failure
   count, and min/max/average response time.
2. **Given** a data file, **When** the operator requests a summary filtered to a time range,
   **Then** only records within that range are included in the output.
3. **Given** no records exist for a requested target or time range, **When** a summary is requested,
   **Then** the tool reports zero records found rather than erroring.

---

### User Story 3 - Configure Targets and Schedule (Priority: P3)

An operator sets up or modifies the list of targets and probe interval via a configuration file,
without needing to pass all options as CLI flags on every invocation.

**Why this priority**: Operators running this as a background service need stable, repeatable
configuration. A config file is essential for automation.

**Independent Test**: Write a config file with three targets and a custom interval, start the monitor
pointing at that config, verify probes are sent to all three targets at the specified interval.

**Acceptance Scenarios**:

1. **Given** a config file specifying three targets and a 30-second interval, **When** the monitor
   starts, **Then** it probes all three targets at that interval without requiring those values as
   CLI flags.
2. **Given** a config file with an invalid target entry (empty string), **When** the monitor starts,
   **Then** it reports the invalid entry and exits with a non-zero status rather than silently
   skipping it.
3. **Given** no config file exists at the expected path, **When** the monitor starts, **Then** it
   prints a clear error message indicating the config file is missing and exits non-zero.

---

### Edge Cases

- What happens when a target DNS name cannot be resolved? A failure record MUST be saved with a
  "DNS resolution failure" reason; the monitor MUST continue probing other targets.
- What happens if the data directory is not writable? The monitor MUST fail fast with a clear error
  on startup rather than silently losing data.
- What happens if a probe takes longer than the probe interval? The next probe for that target MUST
  be scheduled from the end of the previous probe, not the start, to avoid overlapping probes.
- What happens if the same target appears twice in the config? The tool MUST deduplicate and warn
  the user rather than probing the target twice.
- What happens when the monitor is interrupted mid-write? The data file MUST never be left in a
  corrupt state; partial writes MUST be recoverable or discarded.
- What happens if `--duration` is set to less than one probe interval? The monitor MUST emit a
  warning and run at least one full probe cycle before exiting.
- What happens if `--duration` value is not a valid Go-style duration string? The monitor MUST
  exit at startup with a descriptive parse error and non-zero status.
- What happens when the tool is run without root / `CAP_NET_RAW`? The tool MUST detect the missing
  privilege at startup, print a clear error explaining that ICMP requires elevated permissions, and
  exit with a non-zero status.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST probe each configured target at the configured interval and record the
  result to disk.
- **FR-002**: System MUST record per-probe: timestamp (UTC), target identifier, round-trip time
  (milliseconds), and success/failure status with failure reason when applicable.
- **FR-003**: System MUST append new results to existing data files; prior history MUST NOT be
  overwritten on restart.
- **FR-004**: System MUST continue probing remaining targets after any individual probe failure
  (timeout, DNS failure, unreachable host).
- **FR-005**: System MUST support loading target list and probe interval from a TOML configuration
  file.
- **FR-006**: System MUST validate configuration on startup and exit with a descriptive error for
  any invalid or missing required fields.
- **FR-007**: System MUST provide a read/report command that summarises stored data for a given
  target, including uptime percentage, failure count, and response time statistics. Output MUST
  be a human-readable table by default; a `--json` flag MUST emit the same data as structured JSON.
- **FR-008**: System MUST support filtering the report output by time range.
- **FR-009**: Probe dispatch MUST be concurrent across targets; one slow or failing target MUST NOT
  delay probes to other targets.
- **FR-010**: System MUST handle SIGINT/SIGTERM gracefully (Ctrl-C triggers SIGINT); on receipt,
  the monitor MUST complete any in-flight probe writes, print a final summary, and exit with
  zero status. When no `--duration` is specified, SIGINT/SIGTERM is the only stop mechanism.
- **FR-011**: System MUST verify it has raw socket privileges (root or `CAP_NET_RAW`) at startup
  and exit with a descriptive error if absent.
- **FR-012**: After each probe interval cycle completes, the monitor MUST print a summary line to
  stdout for each target containing: cumulative probes sent, cumulative error count, and average
  round-trip time across all successful probes to date. When `--json` is passed to
  `pinger monitor`, each cycle summary MUST be emitted as a single JSON object per target instead
  of plain text.
- **FR-013**: System MUST support an optional `--duration` parameter accepting Go-style duration
  strings (e.g., `30s`, `5m`, `1h`, `1h30m`) specifying total collection run time; when the
  duration elapses, the monitor MUST complete the current probe cycle, flush all writes, print
  a final summary, and exit with zero status.

### Key Entities

- **Target**: A network endpoint to probe. Attributes: identifier (label), address
  (hostname or IP), optional per-target timeout override (default: 5 seconds).
- **ProbeResult**: One recorded measurement. Attributes: timestamp (UTC), target identifier,
  success (bool), round-trip time (ms, null on failure), failure reason (string, null on success).
- **MonitorConfig**: Runtime configuration. Stored as TOML. Attributes: targets (list of Target), probe interval
  (seconds), probe timeout (seconds, default 5), duration (optional, seconds, null = run
  indefinitely), data directory path, output file name pattern.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can configure the monitor and have it running in under 2 minutes from
  a clean install with no prior knowledge of the tool.
- **SC-002**: Probe records for all configured targets are written to disk within 2 seconds of
  each probe completing, regardless of other targets' probe status.
- **SC-003**: After 24 hours of continuous operation with up to 10 targets at 60-second intervals,
  the data file is complete with no missing records and no data corruption.
- **SC-004**: The report command returns a connectivity summary for any target in under 1 second
  for data files containing up to 100,000 records.
- **SC-005**: 100% of probe failures are recorded — no failure is silently discarded.

## Clarifications

### Session 2026-05-27

- Q: What should the tool do when run without root / `CAP_NET_RAW`? → A: Require root / `CAP_NET_RAW`; exit with clear error if missing (no fallback).
- Q: What data storage format should probe results use? → A: JSON Lines (`.jsonl`) — one JSON object per line, append-only.
- Q: What should the monitor print to stdout while running? → A: After each interval cycle, print a summary line per target showing: probes sent (cumulative), error count (cumulative), and average RTT.
- Q: What is the default per-probe timeout? → A: 5 seconds.
- Q: What is the expected maximum number of targets? → A: Up to 10 targets.

### Session 2026-05-27 (continued)

- Q: What format should the configuration file use? → A: TOML.
- Q: What output format should the report command use? → A: Human-readable table by default; `--json` flag emits structured JSON.
- Q: What format should the `--duration` parameter accept? → A: Go-style duration strings: `30s`, `5m`, `1h`, `1h30m`.

## Assumptions

- Targets are specified as hostnames or IP addresses; URL schemes (http://) are out of scope for v1.
- ICMP ping is the probing mechanism; application-layer checks (HTTP, TCP) are out of scope for v1.
- The tool requires root or `CAP_NET_RAW`; no fallback to unprivileged mechanisms or TCP echo.
- The tool runs on Linux/macOS; Windows support is out of scope for v1.
- Data is stored locally on disk; remote storage or streaming to a time-series database is out
  of scope for v1.
- No authentication or access control is required for the CLI; the tool is single-user.
- The operator is responsible for running the monitor as a background process (e.g., via systemd or
  nohup); the tool does not daemonise itself.
- Probe interval is uniform across all targets; per-target interval overrides are out of scope for v1.
- Maximum supported target count is 10; behaviour beyond 10 targets is undefined for v1.
- Data is stored as JSON Lines (`.jsonl`): one JSON object per line, one file per calendar day
  (`pinger-YYYY-MM-DD.jsonl`). Format is append-only; each line is a complete `ProbeResult` record.
