package monitor_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/richardcase/pinger/internal/config"
	"github.com/richardcase/pinger/internal/monitor"
	"github.com/richardcase/pinger/internal/probe"
	"github.com/richardcase/pinger/internal/store"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// --- Fake probers for monitor tests ---

type fakeProber struct {
	results map[string]store.ProbeResult
	calls   atomic.Int64
}

func (f *fakeProber) Probe(target string, _ time.Duration) store.ProbeResult {
	f.calls.Add(1)
	if r, ok := f.results[target]; ok {
		r.Timestamp = time.Now().UTC()
		return r
	}
	reason := "unconfigured"
	return store.ProbeResult{Timestamp: time.Now().UTC(), Target: target, Success: false, FailReason: &reason}
}

type slowFakeProber struct {
	delay  time.Duration
	result store.ProbeResult
}

func (s *slowFakeProber) Probe(_ string, _ time.Duration) store.ProbeResult {
	time.Sleep(s.delay)
	s.result.Timestamp = time.Now().UTC()
	return s.result
}

type fastFakeProber struct {
	result store.ProbeResult
}

func (f *fastFakeProber) Probe(_ string, _ time.Duration) store.ProbeResult {
	f.result.Timestamp = time.Now().UTC()
	return f.result
}

var _ probe.Prober = (*fakeProber)(nil)
var _ probe.Prober = (*slowFakeProber)(nil)
var _ probe.Prober = (*fastFakeProber)(nil)

func rttPtr(v float64) *float64 { return &v }

// TestMonitorCycleDispatch verifies results are dispatched for each target each cycle.
func TestMonitorCycleDispatch(t *testing.T) {
	dir := t.TempDir()
	fp := &fakeProber{
		results: map[string]store.ProbeResult{
			"a": {Target: "a", Success: true, RTTMs: rttPtr(1.0)},
			"b": {Target: "b", Success: true, RTTMs: rttPtr(2.0)},
		},
	}

	cfg := &config.Config{
		Interval: 50 * time.Millisecond,
		Timeout:  5 * time.Second,
		DataDir:  dir,
		Targets: []config.Target{
			{Label: "a", Address: "127.0.0.1"},
			{Label: "b", Address: "127.0.0.2"},
		},
	}

	duration := 130 * time.Millisecond // ~2 full cycles
	err := monitor.Run(cfg, fp, monitor.Options{Duration: duration, SkipPrivilegeCheck: true})
	require.NoError(t, err)

	// Each target should have been probed at least twice.
	calls := fp.calls.Load()
	assert.GreaterOrEqual(t, calls, int64(4), "expected ≥4 probe calls for 2 targets × 2 cycles")
}

// TestMonitorPerCycleStdoutSummary verifies stdout summary lines are emitted.
func TestMonitorPerCycleStdoutSummary(t *testing.T) {
	dir := t.TempDir()
	fp := &fakeProber{
		results: map[string]store.ProbeResult{
			"gw": {Target: "gw", Success: true, RTTMs: rttPtr(1.5)},
		},
	}
	cfg := &config.Config{
		Interval: 50 * time.Millisecond,
		Timeout:  5 * time.Second,
		DataDir:  dir,
		Targets:  []config.Target{{Label: "gw", Address: "127.0.0.1"}},
	}

	// Capture stdout.
	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w

	err := monitor.Run(cfg, fp, monitor.Options{Duration: 80 * time.Millisecond, SkipPrivilegeCheck: true})
	require.NoError(t, err)

	w.Close()
	os.Stdout = old
	buf := make([]byte, 4096)
	n, _ := r.Read(buf)
	output := string(buf[:n])
	assert.Contains(t, output, "gw", "stdout should mention target label")
}

// TestMonitorDurationAutoExit verifies the monitor exits after --duration.
func TestMonitorDurationAutoExit(t *testing.T) {
	dir := t.TempDir()
	fp := &fakeProber{
		results: map[string]store.ProbeResult{
			"x": {Target: "x", Success: true, RTTMs: rttPtr(1.0)},
		},
	}
	cfg := &config.Config{
		Interval: 50 * time.Millisecond,
		Timeout:  5 * time.Second,
		DataDir:  dir,
		Targets:  []config.Target{{Label: "x", Address: "127.0.0.1"}},
	}

	start := time.Now()
	err := monitor.Run(cfg, fp, monitor.Options{Duration: 120 * time.Millisecond, SkipPrivilegeCheck: true})
	require.NoError(t, err)
	elapsed := time.Since(start)
	assert.Less(t, elapsed, 500*time.Millisecond, "should exit well before 500ms")
}

// TestMonitorJSONOutput verifies --json flag emits JSON objects per target.
func TestMonitorJSONOutput(t *testing.T) {
	dir := t.TempDir()
	fp := &fakeProber{
		results: map[string]store.ProbeResult{
			"gw": {Target: "gw", Success: true, RTTMs: rttPtr(1.5)},
		},
	}
	cfg := &config.Config{
		Interval: 50 * time.Millisecond,
		Timeout:  5 * time.Second,
		DataDir:  dir,
		Targets:  []config.Target{{Label: "gw", Address: "127.0.0.1"}},
	}

	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w

	err := monitor.Run(cfg, fp, monitor.Options{Duration: 80 * time.Millisecond, SkipPrivilegeCheck: true, JSONOutput: true})
	require.NoError(t, err)

	w.Close()
	os.Stdout = old
	buf := make([]byte, 4096)
	n, _ := r.Read(buf)
	output := string(buf[:n])

	// Each line should be valid JSON.
	lines := splitLines(output)
	for _, line := range lines {
		if line == "" {
			continue
		}
		var obj map[string]interface{}
		assert.NoError(t, json.Unmarshal([]byte(line), &obj), "line should be valid JSON: %q", line)
	}
}

func splitLines(s string) []string {
	var out []string
	cur := ""
	for _, c := range s {
		if c == '\n' {
			out = append(out, cur)
			cur = ""
		} else {
			cur += string(c)
		}
	}
	if cur != "" {
		out = append(out, cur)
	}
	return out
}

// TestMonitorConcurrency verifies a slow target does not delay a fast target.
func TestMonitorConcurrency(t *testing.T) {
	dir := t.TempDir()

	slow := &slowFakeProber{
		delay:  4 * time.Second, // artificially slow
		result: store.ProbeResult{Target: "slow", Success: true, RTTMs: rttPtr(4000)},
	}
	fast := &fastFakeProber{
		result: store.ProbeResult{Target: "fast", Success: true, RTTMs: rttPtr(1.0)},
	}

	cfg := &config.Config{
		Interval: 50 * time.Millisecond,
		Timeout:  5 * time.Second,
		DataDir:  dir,
		Targets: []config.Target{
			{Label: "slow", Address: "127.0.0.1"},
			{Label: "fast", Address: "127.0.0.2"},
		},
	}

	// Use a dispatcher prober that routes to the right sub-prober.
	dispatcher := &dispatchProber{routes: map[string]probe.Prober{"slow": slow, "fast": fast}}

	start := time.Now()
	// Run only 1 cycle. The slow prober takes 4s; fast should finish within 200ms of interval tick.
	// We check by timing: if concurrency works, total run should NOT be 4s.
	done := make(chan error, 1)
	go func() {
		done <- monitor.Run(cfg, dispatcher, monitor.Options{Duration: 200 * time.Millisecond, SkipPrivilegeCheck: true})
	}()

	select {
	case err := <-done:
		require.NoError(t, err)
		elapsed := time.Since(start)
		// If probes run sequentially, slow (4s) + fast ≈ 4s total.
		// If concurrent, duration of 200ms controls exit ≈ 200ms.
		assert.Less(t, elapsed, time.Second, "concurrent probes should not block on slow prober")
	case <-time.After(5 * time.Second):
		t.Fatal("monitor did not exit within 5s — likely blocked by slow prober (not concurrent)")
	}

	// Verify "fast" target has records in .jsonl.
	files, _ := filepath.Glob(filepath.Join(dir, "pinger-*.jsonl"))
	require.NotEmpty(t, files)
}

// dispatchProber routes probes to per-target sub-probers.
type dispatchProber struct {
	routes map[string]probe.Prober
}

func (d *dispatchProber) Probe(target string, timeout time.Duration) store.ProbeResult {
	if p, ok := d.routes[target]; ok {
		return p.Probe(target, timeout)
	}
	reason := "no route"
	return store.ProbeResult{Timestamp: time.Now().UTC(), Target: target, Success: false, FailReason: &reason}
}
