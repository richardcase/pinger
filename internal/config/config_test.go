package config_test

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/richardcase/pinger/internal/config"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func writeTOML(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "pinger.toml")
	require.NoError(t, os.WriteFile(path, []byte(content), 0644))
	return path
}

func TestLoadValidConfig(t *testing.T) {
	path := writeTOML(t, `
interval = "30s"

[[targets]]
label   = "gateway"
address = "192.168.1.1"

[[targets]]
label   = "dns"
address = "8.8.8.8"
timeout = "3s"
`)
	cfg, err := config.Load(path)
	require.NoError(t, err)
	assert.Equal(t, 30*time.Second, cfg.Interval)
	assert.Equal(t, 5*time.Second, cfg.Timeout, "default timeout should be 5s")
	assert.Equal(t, ".", cfg.DataDir, "default data_dir should be '.'")
	assert.Len(t, cfg.Targets, 2)
	assert.Equal(t, "gateway", cfg.Targets[0].Label)
	assert.Equal(t, "dns", cfg.Targets[1].Label)
	require.NotNil(t, cfg.Targets[1].Timeout)
	assert.Equal(t, 3*time.Second, *cfg.Targets[1].Timeout)
}

func TestLoadDefaultTimeout(t *testing.T) {
	path := writeTOML(t, `
interval = "1m"
[[targets]]
label   = "x"
address = "1.1.1.1"
`)
	cfg, err := config.Load(path)
	require.NoError(t, err)
	assert.Equal(t, 5*time.Second, cfg.Timeout)
}

func TestLoadDefaultDataDir(t *testing.T) {
	path := writeTOML(t, `
interval = "1m"
[[targets]]
label   = "x"
address = "1.1.1.1"
`)
	cfg, err := config.Load(path)
	require.NoError(t, err)
	assert.Equal(t, ".", cfg.DataDir)
}

// --- T030: Validation errors ---

func TestValidateEmptyTargetLabel(t *testing.T) {
	cfg := &config.Config{
		Interval: 30 * time.Second,
		Timeout:  5 * time.Second,
		DataDir:  ".",
		Targets:  []config.Target{{Label: "", Address: "1.1.1.1"}},
	}
	err := config.Validate(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "empty label")
}

func TestValidateDuplicateLabels(t *testing.T) {
	cfg := &config.Config{
		Interval: 30 * time.Second,
		Timeout:  5 * time.Second,
		DataDir:  ".",
		Targets: []config.Target{
			{Label: "gw", Address: "1.1.1.1"},
			{Label: "gw", Address: "2.2.2.2"},
		},
	}
	err := config.Validate(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "duplicate target label")
}

func TestValidateDuplicateAddresses(t *testing.T) {
	cfg := &config.Config{
		Interval: 30 * time.Second,
		Timeout:  5 * time.Second,
		DataDir:  ".",
		Targets: []config.Target{
			{Label: "a", Address: "1.1.1.1"},
			{Label: "b", Address: "1.1.1.1"},
		},
	}
	err := config.Validate(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "duplicate target address")
}

func TestValidateMoreThan10Targets(t *testing.T) {
	var targets []config.Target
	for i := 0; i < 11; i++ {
		targets = append(targets, config.Target{
			Label:   fmt.Sprintf("t%d", i),
			Address: fmt.Sprintf("10.0.0.%d", i+1),
		})
	}
	cfg := &config.Config{
		Interval: 30 * time.Second,
		Timeout:  5 * time.Second,
		DataDir:  ".",
		Targets:  targets,
	}
	err := config.Validate(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "maximum is 10")
}

func TestValidateMissingInterval(t *testing.T) {
	cfg := &config.Config{
		Interval: 0,
		Timeout:  5 * time.Second,
		DataDir:  ".",
		Targets:  []config.Target{{Label: "a", Address: "1.1.1.1"}},
	}
	err := config.Validate(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "interval")
}

func TestValidateZeroInterval(t *testing.T) {
	cfg := &config.Config{
		Interval: 0,
		Timeout:  5 * time.Second,
		DataDir:  ".",
		Targets:  []config.Target{{Label: "a", Address: "1.1.1.1"}},
	}
	err := config.Validate(cfg)
	require.Error(t, err)
}

func TestValidateZeroTimeout(t *testing.T) {
	cfg := &config.Config{
		Interval: 30 * time.Second,
		Timeout:  0,
		DataDir:  ".",
		Targets:  []config.Target{{Label: "a", Address: "1.1.1.1"}},
	}
	err := config.Validate(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "timeout")
}

func TestValidateEmptyDataDir(t *testing.T) {
	cfg := &config.Config{
		Interval: 30 * time.Second,
		Timeout:  5 * time.Second,
		DataDir:  "",
		Targets:  []config.Target{{Label: "a", Address: "1.1.1.1"}},
	}
	err := config.Validate(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "data_dir")
}

func TestValidateNoTargets(t *testing.T) {
	cfg := &config.Config{
		Interval: 30 * time.Second,
		Timeout:  5 * time.Second,
		DataDir:  ".",
		Targets:  nil,
	}
	err := config.Validate(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "at least 1 target")
}

func TestValidateEmptyTargetAddress(t *testing.T) {
	cfg := &config.Config{
		Interval: 30 * time.Second,
		Timeout:  5 * time.Second,
		DataDir:  ".",
		Targets:  []config.Target{{Label: "a", Address: ""}},
	}
	err := config.Validate(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "empty address")
}

func TestLoadMissingFile(t *testing.T) {
	_, err := config.Load("/nonexistent/path/pinger.toml")
	require.Error(t, err)
}

func TestLoadMissingInterval(t *testing.T) {
	path := writeTOML(t, `
[[targets]]
label   = "x"
address = "1.1.1.1"
`)
	_, err := config.Load(path)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "interval")
}

func TestLoadWithExplicitDataDir(t *testing.T) {
	path := writeTOML(t, `
interval = "1m"
data_dir = "/tmp/pinger-test"
[[targets]]
label   = "x"
address = "1.1.1.1"
`)
	cfg, err := config.Load(path)
	require.NoError(t, err)
	assert.Equal(t, "/tmp/pinger-test", cfg.DataDir)
}
