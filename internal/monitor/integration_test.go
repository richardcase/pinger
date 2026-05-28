//go:build integration

package monitor_test

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/richardcase/pinger/internal/config"
	"github.com/richardcase/pinger/internal/monitor"
	"github.com/richardcase/pinger/internal/probe"
	"github.com/richardcase/pinger/internal/store"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMonitorIntegration runs the monitor against 127.0.0.1 for 3 cycles (requires root).
func TestMonitorIntegration(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("integration test requires root")
	}

	dir := t.TempDir()
	interval := 500 * time.Millisecond
	cfg := &config.Config{
		Interval: interval,
		Timeout:  2 * time.Second,
		DataDir:  dir,
		Targets:  []config.Target{{Label: "loopback", Address: "127.0.0.1"}},
	}

	// Run for just over 3 intervals so we get ≥3 cycles.
	duration := interval*3 + 200*time.Millisecond
	err := monitor.Run(cfg, &probe.ICMPProber{}, monitor.Options{Duration: duration})
	require.NoError(t, err)

	files, err := filepath.Glob(filepath.Join(dir, "pinger-*.jsonl"))
	require.NoError(t, err)
	require.NotEmpty(t, files, "expected at least one .jsonl file")

	records, err := store.ReadResults(dir, "loopback", time.Time{}, time.Time{})
	require.NoError(t, err)

	successes := 0
	for _, r := range records {
		if r.Success && r.RTTMs != nil && *r.RTTMs > 0 {
			successes++
		}
	}
	assert.GreaterOrEqual(t, successes, 3, "expected ≥3 success records with RTT > 0")
}

// TestMonitorIntegrationMultiTarget loads a 3-target config and checks all targets have records (T034).
func TestMonitorIntegrationMultiTarget(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("integration test requires root")
	}

	dir := t.TempDir()
	interval := 500 * time.Millisecond
	cfg := &config.Config{
		Interval: interval,
		Timeout:  2 * time.Second,
		DataDir:  dir,
		Targets: []config.Target{
			{Label: "lo1", Address: "127.0.0.1"},
			{Label: "lo2", Address: "127.0.0.2"},
			{Label: "lo3", Address: "127.0.0.3"},
		},
	}

	duration := interval + 200*time.Millisecond // 1 cycle
	err := monitor.Run(cfg, &probe.ICMPProber{}, monitor.Options{Duration: duration})
	require.NoError(t, err)

	for _, label := range []string{"lo1", "lo2", "lo3"} {
		records, err := store.ReadResults(dir, label, time.Time{}, time.Time{})
		require.NoError(t, err)
		assert.NotEmpty(t, records, "expected records for target %q", label)
	}
}
