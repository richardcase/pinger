package report

import (
	"math"
	"time"

	"github.com/richardcase/pinger/internal/store"
)

type ReportSummary struct {
	Target      string    `json:"target"`
	From        time.Time `json:"from"`
	To          time.Time `json:"to"`
	TotalProbes int       `json:"total_probes"`
	Successes   int       `json:"successes"`
	Failures    int       `json:"failures"`
	UptimePct   float64   `json:"uptime_pct"`
	MinRTTMs    float64   `json:"min_rtt_ms"`
	MaxRTTMs    float64   `json:"max_rtt_ms"`
	AvgRTTMs    float64   `json:"avg_rtt_ms"`
}

// Summarise aggregates a slice of ProbeResult into a ReportSummary.
func Summarise(target string, records []store.ProbeResult) ReportSummary {
	rs := ReportSummary{Target: target, MinRTTMs: math.MaxFloat64}

	for _, r := range records {
		if rs.TotalProbes == 0 {
			rs.From = r.Timestamp
			rs.To = r.Timestamp
		} else {
			if r.Timestamp.Before(rs.From) {
				rs.From = r.Timestamp
			}
			if r.Timestamp.After(rs.To) {
				rs.To = r.Timestamp
			}
		}
		rs.TotalProbes++
		if r.Success && r.RTTMs != nil {
			rs.Successes++
			rs.AvgRTTMs += *r.RTTMs
			if *r.RTTMs < rs.MinRTTMs {
				rs.MinRTTMs = *r.RTTMs
			}
			if *r.RTTMs > rs.MaxRTTMs {
				rs.MaxRTTMs = *r.RTTMs
			}
		} else {
			rs.Failures++
		}
	}

	if rs.TotalProbes == 0 {
		rs.MinRTTMs = 0
		return rs
	}
	if rs.Successes > 0 {
		rs.AvgRTTMs /= float64(rs.Successes)
		rs.UptimePct = float64(rs.Successes) / float64(rs.TotalProbes) * 100
	} else {
		rs.MinRTTMs = 0
	}
	return rs
}
