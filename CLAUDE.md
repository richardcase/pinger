# Pinger — Agent Context

## What This Is

Periodic ICMP ping monitor. Probes configured targets on an interval, appends results as daily JSONL files, and exposes a `report` command for uptime/RTT aggregation.

Module: `github.com/richardcase/pinger`

## Key Directories

| Path | Purpose |
|------|---------|
| `cmd/pinger/` | CLI entry point (Cobra) |
| `internal/config/` | TOML config loading and validation (Viper) |
| `internal/probe/` | ICMP probe interface + go-ping implementation |
| `internal/store/` | JSONL reader/writer; `ProbeResult` struct |
| `internal/report/` | Aggregation logic; table and JSON formatters |
| `internal/monitor/` | Main probe loop, signal handling, cycle orchestration |
| `specs/001-periodic-ping-monitor/` | Full design docs: plan, research, data model, CLI contracts |

## Build & Test

```sh
go build ./cmd/pinger
go test ./...
go test -tags integration ./...   # requires CAP_NET_RAW or root
golangci-lint run
```

Toolchain versions in `.mise.toml`.

## Important Constraints

- ICMP requires root or `CAP_NET_RAW` — integration tests must run with privilege.
- Maximum 10 targets per config.
- Data files (`pinger-YYYY-MM-DD.jsonl`) are append-only; never mutate existing records.
- Probe result timestamps are UTC RFC3339Nano.
- Config uses TOML; `interval` is the only required top-level field (besides at least one `[[targets]]`).

## Release

GoReleaser on `vX.Y.Z` git tag. Produces cross-compiled binaries for Linux/macOS amd64/arm64. See `.goreleaser.yml` and `.github/workflows/release.yml`.

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan:
specs/001-periodic-ping-monitor/plan.md
<!-- SPECKIT END -->
