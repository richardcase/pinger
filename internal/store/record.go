package store

import "time"

type ProbeResult struct {
	Timestamp  time.Time `json:"timestamp"`
	Target     string    `json:"target"`
	Success    bool      `json:"success"`
	RTTMs      *float64  `json:"rtt_ms,omitempty"`
	FailReason *string   `json:"fail_reason,omitempty"`
}
