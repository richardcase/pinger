# Data Model: Periodic Ping Monitor

**Branch**: `001-periodic-ping-monitor` | **Date**: 2026-05-27

## Entities

### Target

Represents a single network endpoint to probe.

```go
// internal/config/config.go
type Target struct {
    Label   string         // unique human identifier, required, non-empty
    Address string         // hostname or IP, required, non-empty
    Timeout *time.Duration // nil = use Config.Timeout (default 5s)
}
```

**Validation rules**:
- `Label` MUST be non-empty and unique within a config file
- `Address` MUST be non-empty; DNS resolution failure is a runtime probe failure, not a config error
- `Timeout` MUST be > 0 when set; nil is valid (inherits global)
- Maximum 10 targets per config file

**TOML representation**:
```toml
[[targets]]
label   = "gateway"
address = "192.168.1.1"

[[targets]]
label   = "dns-primary"
address = "8.8.8.8"
timeout = "3s"   # optional override
```

---

### Config

Runtime configuration loaded from a TOML file.

```go
// internal/config/config.go
type Config struct {
    Interval time.Duration // probe interval, required, > 0
    Timeout  time.Duration // global probe timeout, default 5s
    DataDir  string        // directory for .jsonl files, default "."
    Targets  []Target      // 1..10 targets
}
```

**Validation rules**:
- `Interval` MUST be > 0
- `Timeout` MUST be > 0 (default 5s applied before validation)
- `DataDir` MUST be non-empty; existence and write permissions checked at startup
- `Targets` MUST contain 1–10 entries with no duplicate `Label` or `Address` values
- All fields populated by Viper from TOML; missing required fields produce descriptive errors

**TOML representation**:
```toml
interval = "30s"
timeout  = "5s"   # optional, default 5s
data_dir = "/var/log/pinger"

[[targets]]
label   = "gateway"
address = "192.168.1.1"
```

---

### ProbeResult

One recorded measurement from a single probe attempt.

```go
// internal/store/record.go
type ProbeResult struct {
    Timestamp  time.Time `json:"timestamp"`            // UTC RFC3339Nano
    Target     string    `json:"target"`               // Target.Label
    Success    bool      `json:"success"`
    RTTMs      *float64  `json:"rtt_ms,omitempty"`     // null on failure
    FailReason *string   `json:"fail_reason,omitempty"`// null on success
}
```

**Invariants**:
- `Timestamp` is always UTC
- When `Success == true`: `RTTMs` is non-nil, `FailReason` is nil
- When `Success == false`: `RTTMs` is nil, `FailReason` is non-nil
- `Target` matches a `Target.Label` from the config that produced this record
- `RTTMs` is the full round-trip time in milliseconds (float to preserve sub-ms precision)

**JSONL example** (one line per record):
```json
{"timestamp":"2026-05-27T10:00:00.123456789Z","target":"gateway","success":true,"rtt_ms":1.234}
{"timestamp":"2026-05-27T10:00:00.456789012Z","target":"dns-primary","success":false,"fail_reason":"i/o timeout"}
```

---

### ReportSummary

Derived aggregate computed by the report command. Not persisted.

```go
// internal/report/summary.go
type ReportSummary struct {
    Target      string    `json:"target"`
    From        time.Time `json:"from"`
    To          time.Time `json:"to"`
    TotalProbes int       `json:"total_probes"`
    Successes   int       `json:"successes"`
    Failures    int       `json:"failures"`
    UptimePct   float64   `json:"uptime_pct"`   // 0–100
    MinRTTMs    float64   `json:"min_rtt_ms"`   // 0 if no successes
    MaxRTTMs    float64   `json:"max_rtt_ms"`
    AvgRTTMs    float64   `json:"avg_rtt_ms"`
}
```

---

## File Layout

Data files are named `pinger-YYYY-MM-DD.jsonl` within `Config.DataDir`.
One file per calendar day (UTC). New day = new file; append continues across restarts within
the same day.

```
<data_dir>/
├── pinger-2026-05-27.jsonl
├── pinger-2026-05-28.jsonl
└── ...
```

The report command scans all `.jsonl` files in `DataDir`, filters by target label and optional
time range, then aggregates into a `ReportSummary`.

---

## State Transitions

### ProbeResult lifecycle

```
[ probe dispatched ]
        │
        ├─ ICMP reply received within timeout → Success=true, RTTMs=<measured>
        │
        ├─ timeout elapsed             → Success=false, FailReason="i/o timeout"
        ├─ DNS resolution failure      → Success=false, FailReason="DNS: <error>"
        └─ network unreachable / other → Success=false, FailReason="<error string>"
```

### Monitor lifecycle

```
[ startup ]
    │
    ├─ privilege check fails  → exit 1
    ├─ config invalid         → exit 1
    ├─ data dir not writable  → exit 1
    │
    └─ [ probe loop ]
            │
            ├─ interval tick → dispatch all target goroutines concurrently
            │                   write results → print cycle summary to stdout
            │
            ├─ --duration elapsed → complete current cycle → final summary → exit 0
            │
            └─ SIGINT/SIGTERM     → complete current cycle → final summary → exit 0
```
