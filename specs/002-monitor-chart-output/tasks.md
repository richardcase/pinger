---
description: "Task list for Monitor Realtime Chart Output"
---

# Tasks: Monitor Realtime Chart Output

**Input**: Design documents from `/specs/002-monitor-chart-output/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli.md, quickstart.md

**Tests**: REQUIRED. The project constitution (Principle II) mandates tests alongside implementation, written before/with code, deterministic (no real terminal or network — inject `io.Writer`, size func, and fake probers).

**Organization**: Tasks grouped by user story. NOTE: this feature is a refactor-plus-feature — the shared output seam and the breaking flag changes (`--json` removal, `--display` addition) land in **Foundational** so the codebase compiles and log mode keeps working. US1 delivers the new chart capability; US2/US3 lock the preserved/removed behaviors with tests.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on incomplete tasks)
- **[Story]**: US1 / US2 / US3 (user-story phases only)

## Path Conventions

Single Go module at repo root: `cmd/pinger/`, `internal/monitor/`. No `src/` layout.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Pull in the new dependencies and confirm a clean baseline.

- [X] T001 Add chart dependencies: run `go get github.com/guptarohit/asciigraph` and `go get golang.org/x/term`; verify `go.mod` + `go.sum` updated and `go build ./...` still succeeds.
- [X] T002 [P] Record clean baseline: run `golangci-lint run` and `go test ./...` on the current tree so post-change regressions are attributable.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Introduce the `reporter` seam, migrate `Options.JSONOutput` → `Options.Display`, and rewire the `monitor` flags. After this phase the binary compiles, **log mode is unchanged**, and `--json` is gone. BLOCKS all user stories.

**⚠️ CRITICAL**: No user story work begins until this phase completes.

- [X] T003 Define the `reporter` interface (`cycle(ts time.Time, rows []targetCycle)`, `final(ts time.Time, rows []targetCycle)`) and the `targetCycle` row struct (`Label`, `Sent`, `Errors`, `AvgMs`, `CycleMs *float64`) in `internal/monitor/reporter.go`.
- [X] T004 Add `displayMode` type (`log`, `chart`) and the pure `resolveDisplay(mode string, isTTY bool) (displayMode, error)` validator (unknown value → error naming valid values; `chart` + `!isTTY` → error pointing to `--display log`) in `internal/monitor/reporter.go`.
- [X] T005 Implement `logReporter` in `internal/monitor/reporter.go` writing to an injected `io.Writer`, reproducing today's exact per-cycle line format and final `TOTAL` + `monitor stopped` output (move the format strings out of `monitor.go` verbatim, including the `sent==0` skip).
- [X] T006 In `internal/monitor/monitor.go`: replace `Options.JSONOutput bool` with `Options.Display displayMode`; delete the `encoding/json` console branches; have `runCycle` build `[]targetCycle` and call `reporter.cycle`, and `printFinalSummary` call `reporter.final`. When building rows, capture each target's **this-cycle** RTT (`r.pr.RTTMs`) into `CycleMs` (nil on failure) during the collection loop, alongside the cumulative `Sent/Errors/AvgMs`. Construct a `logReporter` in `Run` for now (chart construction added in US1). (depends T003, T004, T005)
- [X] T007 In `cmd/pinger/main.go` `newMonitorCmd`: remove the `jsonOutput` var and the `--json` flag; add a `--display` string flag (default `log`); resolve it via `monitor.resolveDisplay(display, term.IsTerminal(int(os.Stdout.Fd())))` and return the error on failure; pass the resolved mode into `monitor.Options{Display: ...}`. (depends T004, T006)

**Checkpoint**: `go build ./...` passes; `monitor` (default and `--display log`) behaves exactly as before; `monitor --json` is an unknown flag; `--display chart` validates + TTY-gates but still renders log output (chart arrives in US1).

---

## Phase 3: User Story 1 - Watch RTT live as a chart (Priority: P1) 🎯 MVP

**Goal**: `pinger monitor --display chart` renders a single combined, continuously-updating ASCII line chart of per-target RTT, with failures as gaps, restoring the terminal cleanly on exit.

**Independent Test**: Run `sudo pinger monitor --display chart` on a TTY against configured targets → a live combined chart with one labelled line per target appears and updates each cycle; Ctrl-C restores the terminal and prints the final summary.

### Tests for User Story 1 ⚠️ (write first, ensure they FAIL)

- [X] T008 [US1] Test `chartReporter` renders a combined chart containing every target's legend label and a plotted line, by feeding synthetic `targetCycle` rows and rendering to a `bytes.Buffer` with a fixed injected size, in `internal/monitor/reporter_test.go`. Include a 10-target case asserting 10 distinct legends render (SC-002).
- [X] T009 [US1] Test failure handling + rolling window in `internal/monitor/reporter_test.go`: a cycle where a target failed stores `math.NaN()` for that series (never `0`), and appending more than `width` points caps the buffer and drops the oldest.
- [X] T010 [US1] Integration test in `internal/monitor/monitor_test.go`: `monitor.Run` in chart mode with a fake prober, injected writer + size func, `SkipPrivilegeCheck`, and tiny `--duration` → output contains the alternate-screen enter/leave sequences and, after leave, the final text summary (FR-011 / SC-004).

### Implementation for User Story 1

- [X] T011 [US1] Implement `chartReporter` in `internal/monitor/reporter.go`: per-target ordered rolling buffers appending `CycleMs` each cycle (`math.NaN()` when nil → gap), render via `asciigraph.PlotMany` with `SeriesColors`, `SeriesLegends` (target labels), `Width` (from injected size func), `Height`, `Caption`; write to injected `io.Writer`. Define a fixed palette of ≥10 distinct `asciigraph` colors (cycled if targets exceed palette length) so all 10 max targets stay distinguishable (SC-002). (depends T003)
- [X] T012 [US1] In `chartReporter` (`internal/monitor/reporter.go`): enter alternate screen + hide cursor on first render; on `final`, leave alternate screen + show cursor, then print the same text summary as `logReporter` (FR-011); re-query size each redraw so resize is handled. (depends T011)
- [X] T013 [US1] In `internal/monitor/monitor.go`: add an internal `run(...)` seam that accepts the output `io.Writer` and a size function (default `os.Stdout` + `term.GetSize`), and branch reporter construction — `chart` → `chartReporter`, `log` → `logReporter`; `Run` delegates to it. (depends T006, T011, T012)

**Checkpoint**: chart mode is fully functional and independently testable; MVP deliverable complete.

---

## Phase 4: User Story 2 - Keep existing log-line output as default (Priority: P2)

**Goal**: Default output and `--display log` are byte-for-byte identical to the pre-feature behavior.

**Independent Test**: Run `pinger monitor` (no flag) and `pinger monitor --display log` → output matches the documented log format and final summary exactly.

### Tests for User Story 2 ⚠️

- [X] T014 [US2] Golden test in `internal/monitor/reporter_test.go`: `logReporter.cycle` and `logReporter.final` produce output byte-identical to the pre-feature format (per-cycle `[ts] label sent=N errors=N avg_rtt=Xms` with `sent==0` skip; per-target `TOTAL` lines; trailing `monitor stopped`).
- [X] T015 [US2] Integration test in `internal/monitor/monitor_test.go`: a run with default options and a run with `Display: log` (fake prober, injected writer) produce identical output (SC-005); additionally assert the JSONL records written are byte-identical between `Display: log` and `Display: chart` runs over the same fake-prober sequence (FR-010).

### Implementation for User Story 2

- [X] T016 [US2] If T014/T015 reveal any drift, correct the `logReporter` format strings in `internal/monitor/reporter.go` to match the original output exactly. (verification-driven; no change if already identical)

**Checkpoint**: log parity locked; US1 and US2 both pass independently.

---

## Phase 5: User Story 3 - Retire `--json` from monitor (Priority: P3)

**Goal**: `monitor` no longer accepts `--json`; invalid `--display` and non-TTY chart requests fail clearly. (The removal itself happens in T007; this phase locks the behavior and removes any remnants.)

**Independent Test**: `pinger monitor --json` → non-zero unknown-flag error; `report --json` still works.

### Tests for User Story 3 ⚠️

- [X] T017 [US3] CLI test in `cmd/pinger/main_test.go`: executing the monitor command with `--json` returns a non-nil (unknown-flag) error and does not start probing (FR-008 / SC-006).
- [X] T018 [US3] Table-driven test for `resolveDisplay` in `internal/monitor/reporter_test.go`: `log`/`chart` on TTY succeed; unknown value errors naming valid values (FR-009); `chart` + non-TTY errors pointing to `--display log` (FR-013).

### Implementation for User Story 3

- [X] T019 [US3] Grep-verify and remove any remaining `JSONOutput`, `--json`, or per-cycle `encoding/json` console references in `internal/monitor/monitor.go` and `cmd/pinger/main.go` (the `report` command's `--json` in `cmd/pinger/main.go` MUST remain — FR-012).

**Checkpoint**: all three stories independently functional and tested.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T020 [P] Check `README.md` (and any docs) for `monitor --json` references; update to `--display log|chart`. Leave `report --json` references intact.
- [X] T021 [US1] Terminal-resize unit test in `internal/monitor/reporter_test.go`: a size func returning a changed width on a later render adapts the rolling window without panic.
- [X] T022 Run the `quickstart.md` verification matrix manually: build; `--display chart` on a TTY; `--display chart` piped → exit 1; `--json` → exit 1; Ctrl-C restores terminal + prints summary.
- [X] T023 [P] Record the required MAJOR version bump (breaking `--json` removal, Constitution III) in release notes / `CHANGELOG`, and confirm the next tag reflects it before `goreleaser` runs.
- [X] T024 Final gates: `golangci-lint run`, `go test ./...`, and `go test -tags integration ./...` (privileged) all green.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup. BLOCKS all user stories.
- **US1 (Phase 3)**: depends on Foundational. The MVP.
- **US2 (Phase 4)**: depends on Foundational (its behavior is delivered by T005/T006). Independent of US1 — can run in parallel.
- **US3 (Phase 5)**: depends on Foundational (removal done in T007). Independent of US1/US2 — can run in parallel.
- **Polish (Phase 6)**: after the desired stories complete.

### Within Each Story

- Tests before implementation; verify they fail first.
- `reporter.go` tasks (T003–T005, T011–T012) are sequential — same file.
- `monitor.go` tasks (T006, T013, T019) are sequential — same file.
- `reporter_test.go` tasks (T008, T009, T014, T018, T021) are sequential — same file.

### Parallel Opportunities

- T002 [P] alongside T001 review.
- After Foundational: US1, US2, US3 can proceed in parallel (different developers); note shared-file sequencing above.
- T020 [P] and T023 [P] (docs/release notes — different files) can run anytime in Polish.

---

## Parallel Example: post-Foundational

```bash
# Different developers, after Phase 2 checkpoint:
Dev A → US1: chartReporter + chart wiring + chart tests (reporter.go, monitor.go, reporter_test.go, monitor_test.go)
Dev B → US2: log-parity golden tests (reporter_test.go, monitor_test.go)
Dev C → US3: --json rejection + resolveDisplay tests (main_test.go, reporter_test.go)
# Coordinate writes to shared reporter_test.go / monitor.go.
```

---

## Implementation Strategy

### MVP First (User Story 1)

1. Phase 1 Setup → 2. Phase 2 Foundational (CRITICAL) → 3. Phase 3 US1 → **STOP & VALIDATE** chart on a real TTY → demo.

### Incremental Delivery

1. Setup + Foundational → log mode intact, `--json` removed, compiles.
2. US1 → realtime chart (MVP) → demo.
3. US2 → log-parity tests green.
4. US3 → flag-removal tests green.
5. Polish → docs, resize test, release major-version note, full gates.

---

## Notes

- [P] = different files, no incomplete-task dependency.
- This feature ships a breaking CLI change (`--json` removed) → next release MUST bump the MAJOR version (Constitution III); structured output for monitor data remains via JSONL files + `report --json`.
- All unit/integration tests must run without a real terminal or network (inject writer, size func, fake prober) per Constitution II.
- Commit after each task or logical group; keep `main` releasable.
