# Research: Periodic Ping Monitor

**Branch**: `001-periodic-ping-monitor` | **Date**: 2026-05-27

## Decision Log

### 1. ICMP Probe Library

**Decision**: `github.com/go-ping/ping`

**Rationale**: Mature, widely adopted Go ICMP library. Supports privileged raw-socket mode
(required by FR-011). Exposes a clean `Pinger` interface suitable for mocking in unit tests.
Handles echo request/reply sequencing, timeout, and TTL internally.

**Alternatives considered**:
- `golang.org/x/net/icmp`: Lower-level, full control, but requires significantly more boilerplate
  to implement request sequencing and RTT calculation correctly. Complexity not justified.
- System `ping` binary via `os/exec`: Non-deterministic output format, platform-specific parsing,
  not testable without a real network. Rejected.

**Privileged mode**: Set `pinger.SetPrivileged(true)` to use `SOCK_RAW`. The binary requires
`sudo` or `setcap cap_net_raw+ep` on Linux. Startup privilege check (FR-011) calls
`net.ListenPacket("ip4:icmp", "")` and exits with a clear error if it fails.

---

### 2. Duration Parsing

**Decision**: `time.ParseDuration` (Go stdlib)

**Rationale**: Natively supports `30s`, `5m`, `1h`, `1h30m` — exactly the format decided in
clarifications. Zero additional dependencies. Cobra accepts string flags and the monitor layer
calls `time.ParseDuration` on the raw value.

---

### 3. JSON Lines Storage

**Decision**: stdlib `encoding/json` + `os.OpenFile(O_APPEND|O_CREATE|O_WRONLY)`

**Rationale**: Each `ProbeResult` is marshalled to JSON and written as a single line terminated
by `\n`. `O_APPEND` mode on Linux/macOS makes each write atomic for payloads under `PIPE_BUF`
(4096 bytes, well above our ~200-byte records). One file per day (`pinger-YYYY-MM-DD.jsonl`)
keeps file sizes bounded and enables easy archiving.

**Corruption safety**: Encode to `[]byte` buffer first, then write in one `f.Write(buf)` call.
A partial line (truncated by SIGKILL) is detected on read by a failed `json.Unmarshal` and
skipped, so no record is silently corrupted.

**Read path (report)**: `bufio.Scanner` + `json.Unmarshal` per line. For 100k records at ~200
bytes each = ~20MB, scanned in <100ms on modern hardware — well within SC-004's 1-second target.

---

### 4. Configuration: Viper + TOML

**Decision**: `github.com/spf13/viper` with TOML file format

**Rationale**: Viper is Cobra's natural companion. Handles TOML parsing via
`github.com/pelletier/go-toml/v2` (pulled transitively). Provides typed getters, defaults,
and environment variable overrides with no additional code. TOML chosen in clarifications for
human-friendliness and comment support.

**Config file location**: `--config` flag (default: `./pinger.toml`). Viper's
`SetConfigFile`/`ReadInConfig` handles missing-file detection cleanly.

---

### 5. Concurrency Model

**Decision**: One goroutine per target using `sync.WaitGroup`; results funnelled through a
buffered channel to a single writer goroutine.

**Rationale**: Maximum 10 targets = maximum 10 probe goroutines. No worker pool needed.
Single writer goroutine serialises all file appends without locks. Channel buffer size = number
of targets so no probe goroutine blocks waiting for a write.

**Interval timing**: Each target goroutine tracks its own `time.After` from the end of the
previous probe (not the start), satisfying the overlapping-probe edge case.

---

### 6. Release Pipeline: GoReleaser + GitHub Actions

**Decision**: `.goreleaser.yml` + `.github/workflows/release.yml` triggering on semver tags
(`v*.*.*`)

**Rationale**: GoReleaser handles cross-compilation, binary naming, archive creation, checksum
generation, and GitHub release creation in a single tool. Triggered by pushing a semver tag
(e.g., `git tag v1.0.0 && git push origin v1.0.0`).

**Build matrix**: `linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`.

**Note**: User input referenced "server tag" — interpreted as semver tag.

---

### 7. Tooling: Mise

**Decision**: `.mise.toml` pins Go version, `golangci-lint`, and `goreleaser`

**Rationale**: Mise provides reproducible tool versions across developer machines and CI without
requiring manual installation. Single `mise install` bootstraps the full toolchain.

**Linter**: `golangci-lint` with `errcheck`, `staticcheck`, `govet`, `gofmt`, `gosec` enabled.

---

### 8. Testing Strategy

**Decision**: `github.com/stretchr/testify` for assertions; interface-based mocking for ICMP

**Rationale**: Testify provides `assert`/`require` that produce clear failure messages. The
`probe` package exposes a `Prober` interface; unit tests inject a `FakeProber` returning
deterministic results. Integration tests require root and send real ICMP to `127.0.0.1`.

**Test separation**: Unit tests run without privileges (`go test ./...`). Integration tests
gated by a `//go:build integration` tag, run separately in CI with `sudo`.
