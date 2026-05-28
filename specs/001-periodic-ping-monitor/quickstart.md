# Quickstart: Periodic Ping Monitor

## Prerequisites

- Linux or macOS
- [Mise](https://mise.jdx.dev) installed (`curl https://mise.run | sh`)
- A GitHub account (for releases)
- Root access or `CAP_NET_RAW` capability (for running `pinger monitor`)

## 1. Install Toolchain

```bash
mise install   # installs Go, golangci-lint, goreleaser from .mise.toml
```

## 2. Build

```bash
go build -o pinger ./cmd/pinger
```

## 3. Create a Config File

Save as `pinger.toml`:

```toml
interval = "30s"
data_dir = "./data"

[[targets]]
label   = "gateway"
address = "192.168.1.1"

[[targets]]
label   = "dns"
address = "8.8.8.8"
```

## 4. Run the Monitor

```bash
mkdir -p ./data
sudo ./pinger monitor --config pinger.toml
```

Expected output every 30 seconds:

```
[2026-05-27T10:00:30Z] gateway    sent=1 errors=0 avg_rtt=1.23ms
[2026-05-27T10:00:30Z] dns        sent=1 errors=0 avg_rtt=2.45ms
```

Data is written to `./data/pinger-2026-05-27.jsonl`.

Stop with **Ctrl-C**.

## 5. Run for a Fixed Duration

```bash
sudo ./pinger monitor --config pinger.toml --duration 5m
```

The monitor exits automatically after 5 minutes.

## 6. View a Report

```bash
./pinger report --config pinger.toml --target gateway
```

Filter by time range:

```bash
./pinger report --config pinger.toml --target gateway \
  --from 2026-05-27T00:00:00Z --to 2026-05-27T12:00:00Z
```

Machine-parseable output:

```bash
./pinger report --config pinger.toml --target gateway --json
```

## 7. Run Tests

Unit tests (no root needed):

```bash
go test ./...
```

Integration tests (require root, send real ICMP to loopback):

```bash
sudo go test -tags=integration ./...
```

Lint:

```bash
golangci-lint run
```

## 8. Release

Tag a semver version and push:

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions runs GoReleaser, builds binaries for linux/amd64, linux/arm64, darwin/amd64,
darwin/arm64, and publishes a GitHub Release with checksums.

## Privilege Setup (alternative to sudo)

Grant the binary raw socket access without requiring sudo on every invocation:

```bash
sudo setcap cap_net_raw+ep ./pinger
./pinger monitor --config pinger.toml   # no sudo needed
```
