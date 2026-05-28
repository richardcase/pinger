package report

import (
	"encoding/json"
	"fmt"
	"io"
)

// FormatTable writes a human-readable table for rs to w.
func FormatTable(w io.Writer, rs ReportSummary) {
	if rs.TotalProbes == 0 {
		fmt.Fprintf(w, "no records found for target %q\n", rs.Target)
		return
	}
	fmt.Fprintf(w, "Target:      %s\n", rs.Target)
	fmt.Fprintf(w, "Period:      %s – %s\n", rs.From.Format("2006-01-02 15:04:05Z"), rs.To.Format("2006-01-02 15:04:05Z"))
	fmt.Fprintf(w, "Total:       %d probes\n", rs.TotalProbes)
	fmt.Fprintf(w, "Successes:   %d\n", rs.Successes)
	fmt.Fprintf(w, "Failures:    %d\n", rs.Failures)
	fmt.Fprintf(w, "Uptime:      %.2f%%\n", rs.UptimePct)
	fmt.Fprintf(w, "Min RTT:     %.3f ms\n", rs.MinRTTMs)
	fmt.Fprintf(w, "Max RTT:     %.3f ms\n", rs.MaxRTTMs)
	fmt.Fprintf(w, "Avg RTT:     %.3f ms\n", rs.AvgRTTMs)
}

// FormatJSON marshals rs as indented JSON and writes it to w.
func FormatJSON(w io.Writer, rs ReportSummary) error {
	data, err := json.MarshalIndent(rs, "", "  ")
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(w, string(data))
	return err
}
