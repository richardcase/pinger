package report_test

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/richardcase/pinger/internal/report"
	"github.com/richardcase/pinger/internal/store"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func rttPtr(v float64) *float64 { return &v }
func strPtr(v string) *string   { return &v }

func baseTime() time.Time {
	return time.Date(2026, 5, 27, 10, 0, 0, 0, time.UTC)
}

func makeRecords() []store.ProbeResult {
	t := baseTime()
	return []store.ProbeResult{
		{Timestamp: t, Target: "gw", Success: true, RTTMs: rttPtr(1.0)},
		{Timestamp: t.Add(time.Second), Target: "gw", Success: true, RTTMs: rttPtr(3.0)},
		{Timestamp: t.Add(2 * time.Second), Target: "gw", Success: false, FailReason: strPtr("i/o timeout")},
		{Timestamp: t.Add(3 * time.Second), Target: "gw", Success: true, RTTMs: rttPtr(2.0)},
	}
}

// --- T022: ReportSummary calculation ---

func TestSummaryUptimePct(t *testing.T) {
	rs := report.Summarise("gw", makeRecords())
	// 3 successes out of 4 = 75%
	assert.InDelta(t, 75.0, rs.UptimePct, 0.01)
}

func TestSummaryMinMaxAvgRTT(t *testing.T) {
	rs := report.Summarise("gw", makeRecords())
	assert.InDelta(t, 1.0, rs.MinRTTMs, 0.01, "min RTT")
	assert.InDelta(t, 3.0, rs.MaxRTTMs, 0.01, "max RTT")
	assert.InDelta(t, 2.0, rs.AvgRTTMs, 0.01, "avg RTT") // (1+3+2)/3
}

func TestSummaryZeroRecords(t *testing.T) {
	rs := report.Summarise("gw", nil)
	assert.Equal(t, 0, rs.TotalProbes)
	assert.Equal(t, 0.0, rs.UptimePct)
	assert.Equal(t, 0.0, rs.MinRTTMs)
	assert.Equal(t, 0.0, rs.MaxRTTMs)
	assert.Equal(t, 0.0, rs.AvgRTTMs)
}

func TestSummarySuccessesOnly(t *testing.T) {
	t0 := baseTime()
	records := []store.ProbeResult{
		{Timestamp: t0, Target: "gw", Success: true, RTTMs: rttPtr(5.0)},
		{Timestamp: t0.Add(time.Second), Target: "gw", Success: true, RTTMs: rttPtr(7.0)},
	}
	rs := report.Summarise("gw", records)
	assert.Equal(t, 100.0, rs.UptimePct)
	assert.Equal(t, 0, rs.Failures)
	assert.InDelta(t, 5.0, rs.MinRTTMs, 0.01)
	assert.InDelta(t, 7.0, rs.MaxRTTMs, 0.01)
	assert.InDelta(t, 6.0, rs.AvgRTTMs, 0.01)
}

func TestSummaryFromTo(t *testing.T) {
	rs := report.Summarise("gw", makeRecords())
	assert.Equal(t, baseTime(), rs.From)
	assert.Equal(t, baseTime().Add(3*time.Second), rs.To)
}

// --- T023: table formatter and JSON formatter ---

func TestTableFormatter(t *testing.T) {
	rs := report.Summarise("gw", makeRecords())
	var buf bytes.Buffer
	report.FormatTable(&buf, rs)
	out := buf.String()

	assert.Contains(t, out, "gw", "should include target")
	assert.Contains(t, out, "75", "should include uptime pct")
}

func TestTableFormatterZeroRecords(t *testing.T) {
	rs := report.Summarise("gw", nil)
	var buf bytes.Buffer
	report.FormatTable(&buf, rs)
	out := buf.String()
	assert.True(t, strings.Contains(out, "no records") || strings.Contains(out, "0"), "zero-records message")
}

func TestJSONFormatter(t *testing.T) {
	rs := report.Summarise("gw", makeRecords())
	var buf bytes.Buffer
	require.NoError(t, report.FormatJSON(&buf, rs))
	var got report.ReportSummary
	require.NoError(t, json.Unmarshal(buf.Bytes(), &got))
	assert.Equal(t, "gw", got.Target)
	assert.InDelta(t, 75.0, got.UptimePct, 0.01)
}
