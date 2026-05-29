# Pinger — Agent Context

## What This Is

Periodic ICMP ping monitor. Probes configured targets on an interval, appends results as daily JSONL files, and exposes a `report` command for uptime/RTT aggregation.

Written in **Zig** (toolchain `0.16.0`, pinned in `.mise.toml`). Links libc and uses `std.c` directly for sockets/files/clock; the build defaults to the musl target on Linux (static binaries, and to avoid a host glibc `crt1.o` relocation bug). The sole dependency is `sam701/zig-toml` (pinned in `build.zig.zon`).

## Key Files

| Path | Purpose |
|------|---------|
| `src/main.zig` | Entry point (`main(init: std.process.Init)`) |
| `src/cli.zig` | Command tree, flag parsing, cobra-style help/usage + error framing |
| `src/config.zig` | TOML config loading and validation (via `zig-toml`) |
| `src/probe.zig` | Raw-socket ICMP echo prober (IPv4 + IPv6) + privilege check |
| `src/store/` | JSONL writer (daily files) and reader (glob + filter); `ProbeResult` |
| `src/report/` | Aggregation (`summary.zig`) + table/JSON formatters (`format.zig`) |
| `src/monitor/` | Probe loop, signals, ticker; log + chart reporters; `asciigraph.zig` |
| `src/rfc3339.zig` | RFC3339Nano formatting/parsing (Go-compatible trailing-zero trim) |
| `src/gofmt.zig` | Go-compatible shortest-float, JSON string escaping, `%q` quoting |
| `src/duration.zig` | Go `time.ParseDuration` + `Duration.String()` |
| `src/sys.zig` | libc helpers (fd writes, wall/monotonic clocks) |
| `specs/` | Historical design docs from the original Go implementation |

## Build & Test

```sh
zig build                       # debug build -> zig-out/bin/pinger (musl on Linux)
zig build -Doptimize=ReleaseFast
zig build test                  # unit tests
zig build itest -Dintegration   # build integration test binary -> zig-out/bin/pinger-itest
sudo ./zig-out/bin/pinger-itest # integration tests (raw ICMP needs root/CAP_NET_RAW)
zig fmt --check build.zig src   # lint (formatting)
```

`make build|test|itest|lint|release-local` wrap the above. Toolchain version in `.mise.toml`.

## Important Constraints

- ICMP requires root or `CAP_NET_RAW` — integration tests (and live monitoring) must run with privilege.
- Maximum 10 targets per config.
- Data files (`pinger-YYYY-MM-DD.jsonl`) are append-only; never mutate existing records.
- Probe result timestamps are UTC RFC3339Nano.
- Config uses TOML; `interval` is the only required top-level field (besides at least one `[[targets]]`).
- On-disk JSONL and `report` output are kept byte-for-byte compatible with the original Go tool.

## Release

GitHub Actions on a `vX.Y.Z` git tag cross-compiles with Zig for Linux/macOS amd64/arm64, packages `tar.gz` archives with `sha256sums.txt`, and publishes a release. Version is injected via `-Dversion`. See `.github/workflows/release.yml`.
