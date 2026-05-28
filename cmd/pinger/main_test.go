package main

import (
	"bytes"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMonitorRejectsJSONFlag verifies `monitor --json` fails at flag parse with an
// unknown-flag error and never reaches RunE (FR-008 / SC-006).
func TestMonitorRejectsJSONFlag(t *testing.T) {
	cmd := newMonitorCmd()
	cmd.SetArgs([]string{"--json"})
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetErr(&bytes.Buffer{})

	err := cmd.Execute()
	require.Error(t, err)
	assert.Contains(t, err.Error(), "unknown flag")
}

// TestFlagSurface locks the flag contract: monitor drops --json and gains --display;
// report keeps --json (FR-012).
func TestFlagSurface(t *testing.T) {
	mc := newMonitorCmd()
	assert.Nil(t, mc.Flags().Lookup("json"), "monitor must not expose --json")
	assert.NotNil(t, mc.Flags().Lookup("display"), "monitor must expose --display")

	rc := newReportCmd()
	assert.NotNil(t, rc.Flags().Lookup("json"), "report must keep --json")
}
