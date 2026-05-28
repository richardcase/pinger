package store_test

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/richardcase/pinger/internal/store"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestWriterAppendSemantics(t *testing.T) {
	dir := t.TempDir()
	w, err := store.NewWriter(dir, "")
	require.NoError(t, err)
	defer w.Close()

	rtt := 1.0
	r1 := store.ProbeResult{Timestamp: time.Now().UTC(), Target: "a", Success: true, RTTMs: &rtt}
	r2 := store.ProbeResult{Timestamp: time.Now().UTC(), Target: "b", Success: true, RTTMs: &rtt}

	require.NoError(t, w.Write(r1))
	require.NoError(t, w.Write(r2))

	pattern := filepath.Join(dir, "pinger-*.jsonl")
	files, err := filepath.Glob(pattern)
	require.NoError(t, err)
	require.Len(t, files, 1)

	f, err := os.Open(files[0])
	require.NoError(t, err)
	defer f.Close()

	sc := bufio.NewScanner(f)
	lines := 0
	for sc.Scan() {
		lines++
	}
	assert.Equal(t, 2, lines, "expected 2 JSONL lines")
}

func TestWriterDailyFileNaming(t *testing.T) {
	dir := t.TempDir()
	w, err := store.NewWriter(dir, "")
	require.NoError(t, err)
	defer w.Close()

	ts := time.Date(2026, 5, 27, 10, 0, 0, 0, time.UTC)
	rtt := 2.0
	r := store.ProbeResult{Timestamp: ts, Target: "g", Success: true, RTTMs: &rtt}
	require.NoError(t, w.Write(r))

	expected := filepath.Join(dir, "pinger-2026-05-27.jsonl")
	_, err = os.Stat(expected)
	assert.NoError(t, err, "expected daily file %s to exist", expected)
}

func TestWriterSuccessRecord(t *testing.T) {
	dir := t.TempDir()
	w, err := store.NewWriter(dir, "")
	require.NoError(t, err)
	defer w.Close()

	ts := time.Date(2026, 5, 27, 10, 0, 0, 0, time.UTC)
	rtt := 1.234
	r := store.ProbeResult{Timestamp: ts, Target: "gateway", Success: true, RTTMs: &rtt}
	require.NoError(t, w.Write(r))

	files, _ := filepath.Glob(filepath.Join(dir, "pinger-*.jsonl"))
	require.Len(t, files, 1)
	data, err := os.ReadFile(files[0])
	require.NoError(t, err)

	var got store.ProbeResult
	require.NoError(t, json.Unmarshal(data[:len(data)-1], &got)) // strip trailing newline
	assert.Equal(t, "gateway", got.Target)
	assert.True(t, got.Success)
	assert.NotNil(t, got.RTTMs)
	assert.InDelta(t, 1.234, *got.RTTMs, 0.001)
	assert.Nil(t, got.FailReason)
}

func TestWriterFailureRecord(t *testing.T) {
	dir := t.TempDir()
	w, err := store.NewWriter(dir, "")
	require.NoError(t, err)
	defer w.Close()

	ts := time.Date(2026, 5, 27, 10, 0, 0, 0, time.UTC)
	reason := "i/o timeout"
	r := store.ProbeResult{Timestamp: ts, Target: "dns", Success: false, FailReason: &reason}
	require.NoError(t, w.Write(r))

	files, _ := filepath.Glob(filepath.Join(dir, "pinger-*.jsonl"))
	require.Len(t, files, 1)
	data, err := os.ReadFile(files[0])
	require.NoError(t, err)

	var got store.ProbeResult
	require.NoError(t, json.Unmarshal(data[:len(data)-1], &got))
	assert.Equal(t, "dns", got.Target)
	assert.False(t, got.Success)
	assert.Nil(t, got.RTTMs)
	assert.NotNil(t, got.FailReason)
	assert.Equal(t, "i/o timeout", *got.FailReason)
}

// --- US2 Reader tests (T021) ---

func writeFixture(t *testing.T, dir string, records []store.ProbeResult) {
	t.Helper()
	w, err := store.NewWriter(dir, "")
	require.NoError(t, err)
	for _, r := range records {
		require.NoError(t, w.Write(r))
	}
	w.Close()
}

func rttPtr(v float64) *float64 { return &v }

func TestReaderScanAllFiles(t *testing.T) {
	dir := t.TempDir()
	ts1 := time.Date(2026, 5, 27, 10, 0, 0, 0, time.UTC)
	ts2 := time.Date(2026, 5, 28, 10, 0, 0, 0, time.UTC)
	records := []store.ProbeResult{
		{Timestamp: ts1, Target: "gw", Success: true, RTTMs: rttPtr(1.0)},
		{Timestamp: ts2, Target: "gw", Success: true, RTTMs: rttPtr(2.0)},
	}
	writeFixture(t, dir, records)

	results, err := store.ReadResults(dir, "gw", time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Len(t, results, 2)
}

func TestReaderFilterByTarget(t *testing.T) {
	dir := t.TempDir()
	ts := time.Date(2026, 5, 27, 10, 0, 0, 0, time.UTC)
	records := []store.ProbeResult{
		{Timestamp: ts, Target: "gw", Success: true, RTTMs: rttPtr(1.0)},
		{Timestamp: ts.Add(time.Second), Target: "dns", Success: true, RTTMs: rttPtr(1.5)},
	}
	writeFixture(t, dir, records)

	results, err := store.ReadResults(dir, "gw", time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Len(t, results, 1)
	assert.Equal(t, "gw", results[0].Target)
}

func TestReaderFilterByTimeRange(t *testing.T) {
	dir := t.TempDir()
	base := time.Date(2026, 5, 27, 10, 0, 0, 0, time.UTC)
	records := []store.ProbeResult{
		{Timestamp: base, Target: "gw", Success: true, RTTMs: rttPtr(1.0)},
		{Timestamp: base.Add(time.Hour), Target: "gw", Success: true, RTTMs: rttPtr(2.0)},
		{Timestamp: base.Add(2 * time.Hour), Target: "gw", Success: true, RTTMs: rttPtr(3.0)},
	}
	writeFixture(t, dir, records)

	from := base.Add(30 * time.Minute)
	to := base.Add(90 * time.Minute)
	results, err := store.ReadResults(dir, "gw", from, to)
	require.NoError(t, err)
	assert.Len(t, results, 1)
	assert.InDelta(t, 2.0, *results[0].RTTMs, 0.001)
}

func TestReaderSkipMalformedLines(t *testing.T) {
	dir := t.TempDir()
	ts := time.Date(2026, 5, 27, 10, 0, 0, 0, time.UTC)
	records := []store.ProbeResult{
		{Timestamp: ts, Target: "gw", Success: true, RTTMs: rttPtr(1.0)},
	}
	writeFixture(t, dir, records)

	// Inject a malformed line directly.
	files, _ := filepath.Glob(filepath.Join(dir, "pinger-*.jsonl"))
	require.Len(t, files, 1)
	f, err := os.OpenFile(files[0], os.O_APPEND|os.O_WRONLY, 0644)
	require.NoError(t, err)
	_, err = f.WriteString("not valid json\n")
	require.NoError(t, err)
	f.Close()

	results, err := store.ReadResults(dir, "gw", time.Time{}, time.Time{})
	require.NoError(t, err, "malformed lines should be skipped, not error")
	assert.Len(t, results, 1)
}

// --- IsWritable tests ---

func TestIsWritableSuccess(t *testing.T) {
	dir := t.TempDir()
	err := store.IsWritable(dir)
	assert.NoError(t, err)
}

func TestIsWritableNonExistentDir(t *testing.T) {
	err := store.IsWritable("/nonexistent/path/xyz")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "not writable")
}

// BenchmarkReport100k is defined in reader_test.go (T041) once reader.go exists.
