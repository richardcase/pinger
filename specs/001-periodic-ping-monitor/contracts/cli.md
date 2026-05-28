# CLI Contract: pinger

**Branch**: `001-periodic-ping-monitor` | **Date**: 2026-05-27

## Command Tree

```
pinger
├── monitor   – run continuous ICMP probes and record results
├── report    – summarise stored probe data for a target
└── version   – print version and exit
```

---

## Global Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--config` | string | `./pinger.toml` | Path to TOML configuration file |

Global flags are available on all subcommands.

---

## `pinger monitor`

Run continuous ICMP probes against all configured targets. Requires root or `CAP_NET_RAW`.

### Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--duration` | string | (none) | Stop after this duration (Go duration string: `30s`, `5m`, `1h`) |
| `--json`     | bool   | false  | Emit cycle summaries as JSON objects instead of plain text |

### Behaviour

- Reads config from `--config` file. Exits 1 if missing or invalid.
- Checks raw socket privilege. Exits 1 with message if absent.
- Checks `data_dir` is writable. Exits 1 if not.
- Dispatches one goroutine per target each interval cycle.
- After each cycle, prints one summary line per target to stdout (plain text default):

  ```
  [2026-05-27T10:01:00Z] gateway        sent=5 errors=0 avg_rtt=1.23ms
  [2026-05-27T10:01:00Z] dns-primary    sent=5 errors=1 avg_rtt=2.10ms
  ```

- With `--json`, emits one JSON object per target per cycle instead:

  ```json
  {"timestamp":"2026-05-27T10:01:00Z","target":"gateway","cumulative_sent":5,"cumulative_errors":0,"avg_rtt_ms":1.23}
  {"timestamp":"2026-05-27T10:01:00Z","target":"dns-primary","cumulative_sent":5,"cumulative_errors":1,"avg_rtt_ms":2.10}
  ```

- Appends `ProbeResult` records to `<data_dir>/pinger-YYYY-MM-DD.jsonl`.
- On `--duration` elapsed or SIGINT/SIGTERM: completes current cycle, flushes writes, prints
  final summary identical in format to cycle summary, exits 0.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Clean stop (duration elapsed, SIGINT, or SIGTERM) |
| 1 | Startup error (config invalid, no privilege, unwritable dir) |

### Example

```bash
sudo pinger monitor --config /etc/pinger/pinger.toml --duration 1h
```

---

## `pinger report`

Summarise stored probe data for a single target. Does not require elevated privilege.

### Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--target` | string | (required) | Target label to report on |
| `--from` | string | (none) | Include records at or after this time (RFC3339) |
| `--to` | string | (none) | Include records before or at this time (RFC3339) |
| `--json` | bool | false | Emit output as structured JSON instead of table |

### Default Output (human-readable table)

```
Target:     gateway
Period:     2026-05-27T00:00:00Z – 2026-05-27T23:59:59Z
Probes:     1440
Successes:  1438  (99.86%)
Failures:   2

Response Time (ms):
  Min:   0.81
  Max:   4.72
  Avg:   1.23
```

### JSON Output (`--json`)

```json
{
  "target":      "gateway",
  "from":        "2026-05-27T00:00:00Z",
  "to":          "2026-05-27T23:59:59Z",
  "total_probes": 1440,
  "successes":   1438,
  "failures":    2,
  "uptime_pct":  99.86,
  "min_rtt_ms":  0.81,
  "max_rtt_ms":  4.72,
  "avg_rtt_ms":  1.23
}
```

### Zero-records case

```
No records found for target "gateway" in the specified time range.
```

Exits 0. No error.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Report produced (including zero-records case) |
| 1 | `--target` missing, config invalid, or data dir unreadable |

### Example

```bash
pinger report --target gateway --from 2026-05-27T00:00:00Z --to 2026-05-27T23:59:59Z --json
```

---

## `pinger version`

Print the binary version and exit 0.

```
pinger v1.0.0 (linux/amd64)
```

---

## Error Message Format

All errors follow: `error: <what failed>: <why>. <what to do next>.`

Examples:

```
error: config file not found: open pinger.toml: no such file or directory. Create a config file or pass --config with a valid path.
error: insufficient privilege: raw ICMP sockets require root or CAP_NET_RAW. Run with sudo or grant: sudo setcap cap_net_raw+ep pinger
error: invalid config: target[1].label is empty. Each target must have a non-empty label.
error: invalid --duration "2x": time: unknown unit "x" in duration "2x". Use Go duration format, e.g. 30s, 5m, 1h.
```

---

## Configuration File Format (TOML)

Full example with all supported fields:

```toml
# Probe interval applied to all targets
interval = "60s"

# Global probe timeout (default: 5s)
timeout = "5s"

# Directory for .jsonl data files (default: current directory)
data_dir = "/var/log/pinger"

[[targets]]
label   = "gateway"
address = "192.168.1.1"

[[targets]]
label   = "dns-primary"
address = "8.8.8.8"
timeout = "3s"   # per-target override

[[targets]]
label   = "dns-secondary"
address = "8.8.4.4"
```
