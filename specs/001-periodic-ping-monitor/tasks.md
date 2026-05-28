---
description: "Task list for Periodic Ping Monitor implementation"
---

# Tasks: Periodic Ping Monitor

**Input**: Design documents from `specs/001-periodic-ping-monitor/`

**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅, contracts/cli.md ✅

**Tests**: Included — constitution principle II mandates test-first. Tests MUST fail before
implementation begins. Unit tests use no real network; integration tests (build tag `integration`)
use loopback and require root.

**Organization**: Phases 3–5 map to user stories; each story is independently completable and
testable.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Parallelizable (different files, no incomplete dependencies)
- **[Story]**: US1/US2/US3 — maps to user story in spec.md

---

## Phase 1: Setup

**Purpose**: Project initialization — shared scaffolding with no story dependencies

- [X] T001 Initialize Go module at repository root: `go mod init github.com/richardcase/pinger`
- [X] T002 Create source directory structure per plan.md: `cmd/pinger/`, `internal/config/`, `internal/probe/`, `internal/store/`, `internal/report/`, `internal/monitor/`
- [X] T003 [P] Create `.mise.toml` pinning Go 1.22, golangci-lint 1.57, goreleaser 1.24
- [X] T004 [P] Create `.golangci.yml` enabling errcheck, staticcheck, govet, gofmt, gosec linters

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Types and wiring shared across all user stories

**⚠️ CRITICAL**: No user story work begins until this phase is complete

- [X] T005 Add dependencies to go.mod: `go get github.com/spf13/cobra github.com/spf13/viper github.com/go-ping/ping github.com/stretchr/testify`
- [X] T006 [P] Define `Target` and `Config` structs (types only, no validation) in `internal/config/config.go`
- [X] T007 [P] Define `ProbeResult` struct with JSON tags in `internal/store/record.go`
- [X] T008 [P] Create Cobra root command with `--config` flag (default `./pinger.toml`) in `cmd/pinger/main.go`

**Checkpoint**: Foundation ready — user story phases can now begin in parallel

---

## Phase 3: User Story 1 — Monitor Targets Over Time (Priority: P1) 🎯 MVP

**Goal**: Probe configured targets at interval; append results to daily `.jsonl` file; print
per-cycle summary to stdout; stop gracefully on Ctrl-C, SIGTERM, or `--duration` elapsed.

**Independent Test**: Configure two targets, run for 3 cycles, stop; verify `.jsonl` exists with
timestamped records per target containing RTT or failure reason.

### Tests for User Story 1 ⚠️ Write first — verify FAIL before implementing

- [X] T009 [P] [US1] Write `FakeProber` test double (returns deterministic success/failure results) in `internal/probe/prober_test.go`
- [X] T010 [P] [US1] Write unit tests for JSONL writer: append semantics, daily file naming (`pinger-YYYY-MM-DD.jsonl`), success record, failure record in `internal/store/store_test.go`
- [X] T011 [US1] Write unit tests for monitor loop using `FakeProber`: cycle dispatch, per-cycle stdout summary, `--duration` auto-exit, SIGINT shutdown in `internal/monitor/monitor_test.go`
- [X] T011b [P] [US1] Write concurrency invariant test: inject `SlowFakeProber` (4s artificial delay) for target A and `FastFakeProber` for target B; assert target B's result arrives within 200ms of interval tick in `internal/monitor/monitor_test.go`

### Implementation for User Story 1

- [X] T012 [US1] Define `Prober` interface and implement with `go-ping/ping` in privileged raw-socket mode (configurable timeout) in `internal/probe/prober.go`
- [X] T013 [US1] Implement daily JSONL append writer (`O_APPEND|O_CREATE|O_WRONLY`, encode-then-write for atomicity) in `internal/store/writer.go`
- [X] T014 [US1] Implement monitor orchestration: one goroutine per target per cycle, buffered result channel, single writer goroutine, interval ticker in `internal/monitor/monitor.go`
- [X] T015 [US1] Implement startup checks: raw-socket privilege check (`net.ListenPacket("ip4:icmp", "")`), data dir writable check, descriptive errors in `internal/monitor/monitor.go`
- [X] T016 [US1] Implement per-cycle stdout summary: `[timestamp] <label> sent=N errors=N avg_rtt=Xms` per target (plain text default); emit as JSON object per target when `--json` flag set in `internal/monitor/monitor.go`
- [X] T017 [US1] Implement graceful shutdown: `signal.NotifyContext` for SIGINT/SIGTERM, complete current cycle, flush writes, print final summary, exit 0 in `internal/monitor/monitor.go`
- [X] T018 [US1] Implement `--duration` flag: parse with `time.ParseDuration`, validate > 0, auto-exit after elapsed with final summary; warn if duration < interval in `internal/monitor/monitor.go`
- [X] T019 [US1] Wire `pinger monitor` Cobra subcommand (registers `--duration` and `--json` flags; calls `monitor.Run`) in `cmd/pinger/main.go`
- [X] T020 [US1] Integration test (`//go:build integration`): run monitor against `127.0.0.1` for 3 cycles, assert `.jsonl` contains ≥3 success records with RTT > 0 in `internal/monitor/integration_test.go`

**Checkpoint**: User Story 1 independently functional — `sudo ./pinger monitor --config pinger.toml --duration 30s` produces `.jsonl` data

---

## Phase 4: User Story 2 — View Connectivity History (Priority: P2)

**Goal**: `pinger report --target <label>` scans stored `.jsonl` files and prints uptime%,
failure count, min/max/avg RTT as a table (default) or JSON (`--json`). Supports `--from`/`--to`
RFC3339 time filters.

**Independent Test**: Pre-populate a `.jsonl` fixture with known records, run report, assert
correct uptime%, failure count, and RTT statistics match hand-calculated values.

### Tests for User Story 2 ⚠️ Write first — verify FAIL before implementing

- [X] T021 [P] [US2] Write unit tests for JSONL reader: scan all files in dir, filter by target label, filter by `--from`/`--to`, skip malformed lines in `internal/store/store_test.go`
- [X] T022 [P] [US2] Write unit tests for `ReportSummary` calculation: uptime%, min/max/avg RTT, zero-records case, successes-only case in `internal/report/report_test.go`
- [X] T023 [P] [US2] Write unit tests for table formatter and `--json` formatter output correctness in `internal/report/report_test.go`

### Implementation for User Story 2

- [X] T024 [US2] Implement JSONL file scanner: glob `<data_dir>/pinger-*.jsonl`, `bufio.Scanner` per line, unmarshal, filter by target + optional RFC3339 time bounds in `internal/store/reader.go`
- [X] T025 [US2] Implement `ReportSummary` aggregation from `[]ProbeResult` slice in `internal/report/summary.go`
- [X] T026 [US2] Implement human-readable table formatter (header, stats rows, zero-records message) in `internal/report/format.go`
- [X] T027 [US2] Implement `--json` formatter (marshal `ReportSummary` to indented JSON, print to stdout) in `internal/report/format.go`
- [X] T028 [US2] Wire `pinger report` Cobra subcommand with `--target` (required), `--from`, `--to`, `--json` flags in `cmd/pinger/main.go`

**Checkpoint**: User Stories 1 AND 2 independently functional — `./pinger report --target gateway` shows connectivity history from collected data

---

## Phase 5: User Story 3 — Configure Targets and Schedule (Priority: P3)

**Goal**: Config loaded entirely from TOML file. Validation rejects empty labels, duplicate
labels/addresses, > 10 targets, zero interval. Descriptive errors on any invalid field.

**Independent Test**: Write a TOML file with 3 targets and 30s interval; run `pinger monitor`;
assert all 3 probed at the correct interval without any CLI flags beyond `--config`.

### Tests for User Story 3 ⚠️ Write first — verify FAIL before implementing

- [X] T029 [P] [US3] Write unit tests for TOML config loading: valid config parses correctly, default timeout applied (5s), default data_dir applied (`"."`) in `internal/config/config_test.go`
- [X] T030 [P] [US3] Write unit tests for config validation: empty target label, duplicate labels, duplicate addresses, > 10 targets, missing interval, zero interval all return descriptive errors in `internal/config/config_test.go`

### Implementation for User Story 3

- [X] T031 [US3] Implement Viper TOML config loading with defaults (`timeout=5s`, `data_dir="."`) in `internal/config/config.go`
- [X] T032 [US3] Implement config validation with descriptive `error: ...: why. action.` messages in `internal/config/config.go`
- [X] T033 [US3] Implement target deduplication: detect duplicate `label` or `address` values, warn and deduplicate in `internal/config/config.go`
- [X] T034 [US3] Integration test (`//go:build integration`): load 3-target TOML config, run 1 monitor cycle, assert all 3 targets have records in `.jsonl` in `internal/monitor/integration_test.go`

**Checkpoint**: All three user stories independently functional

---

## Phase 6: Polish & Release Pipeline

**Purpose**: CI/CD, release tooling, and end-to-end validation

- [X] T035 [P] Create `.github/workflows/test.yml`: trigger on PR and push to main; steps: `mise install`, `golangci-lint run`, `go test -cover -coverprofile=coverage.out -covermode=atomic ./...` (fail if coverage < 80%), `go test -bench=. -benchmem ./...`
- [X] T036 [P] Create `.github/workflows/release.yml`: trigger on push of `v*.*.*` tags; steps: `mise install`, `goreleaser release --clean`
- [X] T037 [P] Create `.goreleaser.yml`: build for `linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`; archive as `.tar.gz`; include `sha256sums.txt`; publish GitHub release
- [X] T038 [P] Implement `pinger version` Cobra subcommand printing version string (injected at build time via `-ldflags`) in `cmd/pinger/main.go`
- [X] T040 [P] Write `BenchmarkProbeOverhead` using `FakeProber`: measure per-probe dispatch and record latency, assert < 1ms per operation in `internal/probe/prober_test.go`
- [X] T041 [P] Write `BenchmarkReport100k`: generate 100k fixture `ProbeResult` records, benchmark full JSONL scan + `ReportSummary` aggregation in `internal/store/reader_test.go`
- [ ] T039 Run quickstart.md end-to-end validation: `mise install` → `go build` → create `pinger.toml` → `sudo ./pinger monitor --duration 30s` → verify `.jsonl` → `./pinger report` → assert output matches expected

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (Foundational)**: Depends on Phase 1 — **blocks all user stories**
- **Phase 3 (US1 — P1)**: Depends on Phase 2 — no dependency on US2/US3
- **Phase 4 (US2 — P2)**: Depends on Phase 2 — no dependency on US1 (uses existing `.jsonl` fixtures for tests)
- **Phase 5 (US3 — P3)**: Depends on Phase 2 and Phase 3 (monitor run requires working monitor)
- **Phase 6 (Polish)**: Depends on all user stories complete

### User Story Dependencies

- **US1 (P1)**: Independent after Phase 2
- **US2 (P2)**: Independent after Phase 2 — reads fixture files, no runtime dependency on US1
- **US3 (P3)**: Integration test (T034) depends on US1 monitor being functional

### Within Each User Story

1. Tests MUST be written and FAIL first
2. Implement until tests pass
3. Commit once checkpoint is verified

### Parallel Opportunities

- T003, T004 — Phase 1 setup tasks run in parallel
- T006, T007, T008 — Foundational type definitions run in parallel
- T009, T010 — Test doubles and writer tests run in parallel (Phase 3 test phase)
- T021, T022, T023 — US2 test tasks all parallelizable
- T029, T030 — US3 config test tasks run in parallel
- T035, T036, T037, T038 — All polish tasks run in parallel
- US1 and US2 phases can start in parallel once Phase 2 completes

---

## Parallel Example: User Story 1 Test Phase

```bash
# Launch test tasks for US1 simultaneously (all different files):
Task: "Write FakeProber in internal/probe/prober_test.go"          # T009
Task: "Write JSONL writer unit tests in internal/store/store_test.go"  # T010
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (**CRITICAL** — blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: `sudo ./pinger monitor --config pinger.toml --duration 30s` → inspect `.jsonl`
5. Demonstrate: data collected and persisted

### Incremental Delivery

1. Setup + Foundational → build scaffolding
2. US1 → working monitor → **validate independently** → demo
3. US2 → working report → **validate independently** → demo
4. US3 → robust config loading → **validate independently** → demo
5. Polish + release pipeline → ship

---

## Notes

- `[P]` = different files, no incomplete dependencies — safe to parallelize
- Integration tests require `sudo go test -tags=integration ./...`
- Unit tests run without privilege: `go test ./...`
- Each story checkpoint = independently runnable binary fragment demonstrating that story's value
- Constitution gate: lint must pass (`golangci-lint run`) before each story is considered complete
