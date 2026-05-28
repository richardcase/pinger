<!--
SYNC IMPACT REPORT
==================
Version change: [unversioned template] → 1.0.0
Bump rationale: MINOR — initial principles population from template; no prior version existed.

Modified principles: N/A (first population)
Added sections:
  - I. Code Quality
  - II. Testing Standards
  - III. User Experience Consistency
  - IV. Performance Requirements
  - Quality Gates
  - Development Workflow
  - Governance
Removed sections: N/A

Templates reviewed:
  ✅ .specify/templates/plan-template.md — Constitution Check section present; gates align
  ✅ .specify/templates/spec-template.md — Success Criteria section supports measurable outcomes
  ✅ .specify/templates/tasks-template.md — Test-first tasks and performance/polish phases align
  ✅ .specify/templates/checklist-template.md — not reviewed (no constitution references expected)

Deferred items: None
-->

# Pinger Constitution

## Core Principles

### I. Code Quality

Every line of code MUST be readable, purposeful, and maintainable without supplementary explanation.

- Functions and modules MUST have a single, clear responsibility.
- Dead code, commented-out blocks, and speculative abstractions MUST NOT be committed.
- Names MUST communicate intent; abbreviations are permitted only for universally understood terms.
- Complexity MUST be justified in the commit message or PR description, not in inline comments.
- All PRs MUST pass static analysis and linter checks before review.

**Rationale**: A pinger runs continuously in production. Code that is hard to read is hard to debug
at 2am. Quality is a precondition for reliability.

### II. Testing Standards

Testing is non-negotiable. No feature ships without passing tests that cover its acceptance criteria.

- Unit tests MUST cover all non-trivial logic at the function/module level.
- Integration tests MUST cover every external boundary (network calls, storage, config loading).
- Tests MUST be written before or alongside implementation — never as a post-hoc addition.
- Tests MUST be deterministic: no reliance on real network targets, sleep-based timing, or
  environment-specific paths.
- Coverage MUST not regress; new code MUST be exercised by at least one test per acceptance
  scenario defined in the feature spec.
- Flaky tests MUST be fixed or deleted immediately — a passing-sometimes test is a lie.

**Rationale**: Network monitoring tools fail silently. Tests catch regressions before production
does.

### III. User Experience Consistency

All user-facing output, configuration, and interaction patterns MUST be predictable and uniform
across features.

- CLI flags, config keys, and output fields MUST follow established naming conventions; no
  one-off synonyms.
- Error messages MUST include: what failed, why it failed (if knowable), and what the user can
  do next.
- Success output MUST be parseable (structured JSON flag) AND human-readable (default text mode).
- Any breaking change to a user-facing interface MUST increment the major version.
- New configuration options MUST have documented defaults and MUST NOT require changes to
  existing config files to preserve current behavior.

**Rationale**: Operators script against pinger's output. Inconsistency breaks automation without
warning.

### IV. Performance Requirements

Pinger MUST impose negligible overhead relative to the latency of the targets it monitors.

- Probe round-trip measurement overhead MUST be < 1ms per probe on the local host.
- Memory footprint MUST remain stable under sustained operation; no unbounded growth.
- Startup time MUST be < 500ms from invocation to first probe dispatch.
- Concurrency primitives MUST be used wherever independent probes can be dispatched in
  parallel; sequential polling of independent targets is a defect.
- Performance regressions visible in benchmarks MUST be justified before merge.

**Rationale**: A monitoring tool that distorts measurements or grows without bound cannot be
trusted.

## Quality Gates

All work passes through the following gates before merge:

- **Lint gate**: Zero lint errors; warnings reviewed and explicitly accepted or suppressed with
  justification.
- **Test gate**: All tests pass; coverage does not regress.
- **Constitution check**: PR description MUST reference which principles apply and confirm
  compliance or justify any deviation.
- **Benchmark gate** (performance-impacting changes only): Benchmark results attached to PR;
  no unexplained regression.

Breaking any gate blocks merge. Gates may not be bypassed without explicit team agreement
documented in the PR.

## Development Workflow

- Features begin with a spec (`/speckit-specify`) before any code is written.
- Implementation plans (`/speckit-plan`) MUST include a Constitution Check section.
- Tasks MUST be ordered: tests first, then implementation, then integration.
- Each user story MUST be independently completable, testable, and demonstrable.
- Commits MUST be atomic: one logical change per commit, tests included.
- The `main` branch MUST always be in a releasable state.

## Governance

This constitution supersedes all other development practices. Where a practice conflicts with a
principle here, the constitution wins. Practices not covered by the constitution are at team
discretion.

**Amendment procedure**:
1. Propose amendment in a PR with rationale.
2. At least one team member reviews and approves.
3. Update `LAST_AMENDED_DATE` and increment version per semantic rules.
4. Update all dependent templates as listed in the Sync Impact Report.

**Versioning policy**:
- MAJOR: Principle removed, redefined, or governance mechanism fundamentally changed.
- MINOR: New principle or section added.
- PATCH: Clarification, wording fix, or non-semantic refinement.

**Compliance review**: Each feature spec and plan MUST include a Constitution Check confirming
adherence. Violations require explicit justification in the PR.

**Version**: 1.0.0 | **Ratified**: 2026-05-27 | **Last Amended**: 2026-05-27
