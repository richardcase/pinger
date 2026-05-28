package probe

import (
	"fmt"
	"time"

	probing "github.com/prometheus-community/pro-bing"
	"github.com/richardcase/pinger/internal/store"
)

// Prober sends a single probe to a target and returns the result.
type Prober interface {
	Probe(target string, timeout time.Duration) store.ProbeResult
}

// ICMPProber sends real ICMP echo requests via raw socket (requires root or CAP_NET_RAW).
type ICMPProber struct{}

func (p *ICMPProber) Probe(target string, timeout time.Duration) store.ProbeResult {
	ts := time.Now().UTC()

	pinger, err := probing.NewPinger(target)
	if err != nil {
		reason := fmt.Sprintf("DNS: %s", err.Error())
		return store.ProbeResult{Timestamp: ts, Target: target, Success: false, FailReason: &reason}
	}

	pinger.Count = 1
	pinger.Timeout = timeout
	pinger.SetPrivileged(true)

	if err := pinger.Run(); err != nil {
		reason := err.Error()
		return store.ProbeResult{Timestamp: ts, Target: target, Success: false, FailReason: &reason}
	}

	stats := pinger.Statistics()
	if stats.PacketsRecv == 0 {
		reason := "i/o timeout"
		return store.ProbeResult{Timestamp: ts, Target: target, Success: false, FailReason: &reason}
	}

	rttMs := float64(stats.AvgRtt) / float64(time.Millisecond)
	return store.ProbeResult{Timestamp: ts, Target: target, Success: true, RTTMs: &rttMs}
}
