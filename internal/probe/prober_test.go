package probe_test

import (
	"os"
	"testing"
	"time"

	"github.com/richardcase/pinger/internal/probe"
	"github.com/richardcase/pinger/internal/store"
)

// FakeProber returns deterministic results for unit tests.
type FakeProber struct {
	Results map[string]store.ProbeResult
}

func (f *FakeProber) Probe(target string, _ time.Duration) store.ProbeResult {
	if r, ok := f.Results[target]; ok {
		return r
	}
	reason := "no result configured"
	return store.ProbeResult{
		Timestamp:  time.Now().UTC(),
		Target:     target,
		Success:    false,
		FailReason: &reason,
	}
}

// SlowFakeProber adds artificial delay.
type SlowFakeProber struct {
	Delay   time.Duration
	Results map[string]store.ProbeResult
}

func (s *SlowFakeProber) Probe(target string, _ time.Duration) store.ProbeResult {
	time.Sleep(s.Delay)
	if r, ok := s.Results[target]; ok {
		return r
	}
	reason := "no result configured"
	return store.ProbeResult{
		Timestamp:  time.Now().UTC(),
		Target:     target,
		Success:    false,
		FailReason: &reason,
	}
}

// FastFakeProber returns immediately.
type FastFakeProber struct {
	Results map[string]store.ProbeResult
}

func (f *FastFakeProber) Probe(target string, _ time.Duration) store.ProbeResult {
	if r, ok := f.Results[target]; ok {
		return r
	}
	reason := "no result configured"
	return store.ProbeResult{
		Timestamp:  time.Now().UTC(),
		Target:     target,
		Success:    false,
		FailReason: &reason,
	}
}

func TestFakeProberSuccess(t *testing.T) {
	rtt := 1.5
	fp := &FakeProber{
		Results: map[string]store.ProbeResult{
			"gateway": {Target: "gateway", Success: true, RTTMs: &rtt},
		},
	}
	r := fp.Probe("gateway", 5*time.Second)
	if !r.Success {
		t.Fatal("expected success")
	}
	if r.RTTMs == nil || *r.RTTMs != 1.5 {
		t.Fatalf("expected RTTMs=1.5, got %v", r.RTTMs)
	}
}

func TestFakeProberFailure(t *testing.T) {
	reason := "i/o timeout"
	fp := &FakeProber{
		Results: map[string]store.ProbeResult{
			"bad": {Target: "bad", Success: false, FailReason: &reason},
		},
	}
	r := fp.Probe("bad", 5*time.Second)
	if r.Success {
		t.Fatal("expected failure")
	}
	if r.FailReason == nil || *r.FailReason != "i/o timeout" {
		t.Fatalf("expected fail reason, got %v", r.FailReason)
	}
}

func TestFakeProberMissingTarget(t *testing.T) {
	fp := &FakeProber{Results: map[string]store.ProbeResult{}}
	r := fp.Probe("unknown", 5*time.Second)
	if r.Success {
		t.Fatal("expected failure for unconfigured target")
	}
}

// BenchmarkProbeOverhead is defined here so FakeProber is available; real bench in Phase 6.
func BenchmarkProbeOverhead(b *testing.B) {
	rtt := 0.5
	fp := &FakeProber{
		Results: map[string]store.ProbeResult{
			"t": {Target: "t", Success: true, RTTMs: &rtt},
		},
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = fp.Probe("t", 5*time.Second)
	}
}

// Ensure FakeProber satisfies probe.Prober interface at compile time.
var _ probe.Prober = (*FakeProber)(nil)
var _ probe.Prober = (*SlowFakeProber)(nil)
var _ probe.Prober = (*FastFakeProber)(nil)

// TestICMPProberNoPrivilege verifies ICMPProber returns a failure when raw sockets are unavailable.
// Without root/CAP_NET_RAW, pinger.Run() fails with a permission error.
func TestICMPProberNoPrivilege(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("test requires non-root environment")
	}
	p := &probe.ICMPProber{}
	r := p.Probe("127.0.0.1", 2*time.Second)
	// Without privilege the probe must fail.
	if r.Success {
		t.Fatal("expected failure without raw socket privilege")
	}
	if r.FailReason == nil {
		t.Fatal("expected non-nil FailReason")
	}
}
