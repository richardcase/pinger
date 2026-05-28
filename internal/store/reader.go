package store

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// ReadResults scans all pinger-*.jsonl files in dir, filtering by target label
// and optional time bounds (zero value = no bound).
func ReadResults(dir, target string, from, to time.Time) ([]ProbeResult, error) {
	pattern := filepath.Join(dir, "pinger-*.jsonl")
	files, err := filepath.Glob(pattern)
	if err != nil {
		return nil, err
	}

	var results []ProbeResult
	for _, path := range files {
		f, err := os.Open(path)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Bytes()
			var r ProbeResult
			if err := json.Unmarshal(line, &r); err != nil {
				continue // skip malformed lines
			}
			if r.Target != target {
				continue
			}
			if !from.IsZero() && r.Timestamp.Before(from) {
				continue
			}
			if !to.IsZero() && r.Timestamp.After(to) {
				continue
			}
			results = append(results, r)
		}
		f.Close()
	}
	return results, nil
}
