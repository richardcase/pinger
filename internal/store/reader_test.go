package store_test

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/richardcase/pinger/internal/store"
	"github.com/richardcase/pinger/internal/report"
)

// BenchmarkReport100k benchmarks full JSONL scan + aggregation for 100k records.
func BenchmarkReport100k(b *testing.B) {
	dir := b.TempDir()
	w, err := store.NewWriter(dir, "")
	if err != nil {
		b.Fatal(err)
	}

	base := time.Date(2026, 5, 27, 0, 0, 0, 0, time.UTC)
	rtt := 1.5
	for i := 0; i < 100_000; i++ {
		r := store.ProbeResult{
			Timestamp: base.Add(time.Duration(i) * time.Second),
			Target:    "bench",
			Success:   true,
			RTTMs:     &rtt,
		}
		if err := w.Write(r); err != nil {
			b.Fatal(err)
		}
	}
	w.Close()

	files, _ := filepath.Glob(filepath.Join(dir, "pinger-*.jsonl"))
	b.Logf("fixture: %d files", len(files))

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		records, err := store.ReadResults(dir, "bench", time.Time{}, time.Time{})
		if err != nil {
			b.Fatal(err)
		}
		_ = report.Summarise("bench", records)
	}
}
