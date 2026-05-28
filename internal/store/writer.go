package store

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Writer appends ProbeResult records to daily JSONL files.
type Writer struct {
	dir       string
	fixedPath string
	mu        sync.Mutex
	file      *os.File
	fileDate  string
}

func NewWriter(dir string, fixedPath string) (*Writer, error) {
	return &Writer{dir: dir, fixedPath: fixedPath}, nil
}

func (w *Writer) Write(r ProbeResult) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	date := r.Timestamp.UTC().Format("2006-01-02")
	if err := w.ensureFile(date); err != nil {
		return err
	}

	data, err := json.Marshal(r)
	if err != nil {
		return fmt.Errorf("error: marshal record: %w", err)
	}
	data = append(data, '\n')

	if _, err := w.file.Write(data); err != nil {
		return fmt.Errorf("error: write record: %w", err)
	}
	return nil
}

func (w *Writer) ensureFile(date string) error {
	if w.fixedPath == "" && w.file != nil && w.fileDate == date {
		return nil
	}
	if w.fixedPath != "" && w.file != nil {
		return nil
	}
	if w.file != nil {
		w.file.Close()
	}
	path := filepath.Join(w.dir, fmt.Sprintf("pinger-%s.jsonl", date))
	if w.fixedPath != "" {
		path = w.fixedPath
	}
	fmt.Fprintf(os.Stderr, "output file: %s\n", path)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("error: open data file %s: %w", path, err)
	}
	w.file = f
	w.fileDate = date
	return nil
}

func (w *Writer) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file != nil {
		err := w.file.Close()
		w.file = nil
		return err
	}
	return nil
}

// IsWritable returns nil if dir exists and is writable.
func IsWritable(dir string) error {
	probe := filepath.Join(dir, ".pinger-write-check")
	f, err := os.Create(probe)
	if err != nil {
		return fmt.Errorf("error: data dir %s not writable: %w. Ensure the directory exists and you have write permission.", dir, err)
	}
	f.Close()
	os.Remove(probe)

	// Verify the timestamp-based naming works for today.
	_ = time.Now().UTC().Format("2006-01-02")
	return nil
}
