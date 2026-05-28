# pinger

[![CI](https://github.com/richardcase/pinger/actions/workflows/test.yml/badge.svg)](https://github.com/richardcase/pinger/actions/workflows/test.yml)
[![Release](https://github.com/richardcase/pinger/actions/workflows/release.yml/badge.svg)](https://github.com/richardcase/pinger/actions/workflows/release.yml)

Lightweight CLI tool for periodic ICMP ping monitoring. Probes configured targets on a set interval, stores every result as append-only daily JSONL files, and provides a report command for uptime percentages and RTT statistics.

## Requirements

- Linux or macOS (amd64 / arm64)
- Root or `CAP_NET_RAW` capability (ICMP raw sockets)

## Installation

### Pre-built binaries

Download the latest release for your platform from the [GitHub Releases page](https://github.com/richardcase/pinger/releases). Extract and place the `pinger` binary somewhere on your `$PATH`.

### Build from source

```sh
git clone https://github.com/richardcase/pinger.git
cd pinger
go build -o pinger ./cmd/pinger
```

Requires Go 1.22 or later.

## Configuration

Create a TOML config file. The only required fields are `interval` and at least one `[[targets]]` entry.

```toml
interval = "60s"
timeout  = "5s"          # optional, default 5s
data_dir = "/var/log/pinger"  # optional, default "."

[[targets]]
label   = "gateway"
address = "192.168.1.1"

[[targets]]
label   = "dns-primary"
address = "8.8.8.8"
timeout = "3s"           # per-target override
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `interval` | yes | — | Probe interval (Go duration: `30s`, `1m`, …) |
| `timeout` | no | `5s` | Default probe timeout |
| `data_dir` | no | `.` | Directory for JSONL data files |
| `targets[].label` | yes | — | Unique name used in reports and data files |
| `targets[].address` | yes | — | Hostname or IP to ping |
| `targets[].timeout` | no | global `timeout` | Per-target timeout override |

Maximum 10 targets per config.

## Usage

### Monitor

Run the probe loop. Appends one JSON record per probe to daily files in `data_dir`.

```sh
# Run indefinitely
sudo pinger monitor --config pinger.toml

# Run for a fixed duration
sudo pinger monitor --config pinger.toml --duration 1h

# Watch RTT live as a realtime ASCII chart (requires an interactive terminal)
sudo pinger monitor --config pinger.toml --display chart

# Write data to a specific file instead of daily rotation
sudo pinger monitor --config pinger.toml --output /tmp/probes.jsonl
```

Terminal output mode is selected with `--display`:

- `--display log` (default) — one text summary line per target each cycle.
- `--display chart` — a continuously-updating combined RTT line chart (one colored series per target; failed probes render as gaps). Requires a TTY; errors out when piped or redirected.

Structured per-cycle JSON on stdout (the old `monitor --json`) has been **removed**. Structured data still lives in the daily JSONL files, and `pinger report --json` is unchanged.

Stop with `Ctrl-C` or `SIGTERM`; the process drains the current cycle, restores the terminal (chart mode), and prints the final per-target summary before exiting.

### Report

Aggregate stored results for a target and print uptime and RTT statistics.

```sh
# All data for a target
pinger report --config pinger.toml --target gateway

# Narrow to a time window (RFC3339)
pinger report --config pinger.toml --target gateway \
  --from 2026-05-27T00:00:00Z \
  --to   2026-05-28T00:00:00Z

# JSON output
pinger report --config pinger.toml --target gateway --json
```

Example table output:

```
Target:  gateway
Period:  2026-05-27T00:00:00Z — 2026-05-28T00:00:00Z
Probes:  1440   Success: 1438   Failure: 2
Uptime:  99.86%
RTT:     min 0.81ms  avg 1.23ms  max 8.47ms
```

### Version

```sh
pinger version
```

## Data Format

`data_dir` receives one file per UTC day: `pinger-YYYY-MM-DD.jsonl`. Each line is a self-contained JSON probe result.

```json
{"timestamp":"2026-05-27T10:00:00.123456789Z","target":"gateway","success":true,"rtt_ms":1.234}
{"timestamp":"2026-05-27T10:00:00.456789012Z","target":"dns-primary","success":false,"fail_reason":"i/o timeout"}
```

| Field | Type | Notes |
|-------|------|-------|
| `timestamp` | string | UTC RFC3339Nano |
| `target` | string | Label from config |
| `success` | bool | |
| `rtt_ms` | float \| null | Null on failure |
| `fail_reason` | string \| null | Null on success |

Files are append-only and never modified after writing.

## Running as a Service

To avoid running as root, grant `CAP_NET_RAW` to the binary:

```sh
sudo setcap cap_net_raw+ep /usr/local/bin/pinger
```

For systemd, add to the unit file:

```ini
[Service]
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
```

## Development

```sh
# Unit tests
go test ./...

# Integration tests (requires CAP_NET_RAW or root)
sudo go test -tags integration ./...

# Lint
golangci-lint run

# Build
go build ./cmd/pinger
```

Toolchain versions are managed via [mise](https://mise.jdx.dev/) — see `.mise.toml`.
