package main

import (
	"fmt"
	"os"
	"time"

	"github.com/richardcase/pinger/internal/config"
	"github.com/richardcase/pinger/internal/monitor"
	"github.com/richardcase/pinger/internal/probe"
	"github.com/richardcase/pinger/internal/report"
	"github.com/richardcase/pinger/internal/store"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var cfgFile string
var version = "dev"

var rootCmd = &cobra.Command{
	Use:   "pinger",
	Short: "Periodic ICMP ping monitor",
}

func init() {
	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "./pinger.toml", "config file path")

	rootCmd.AddCommand(newMonitorCmd())
	rootCmd.AddCommand(newReportCmd())
	rootCmd.AddCommand(newVersionCmd())
}

func newMonitorCmd() *cobra.Command {
	var (
		duration   string
		display    string
		outputFile string
	)
	cmd := &cobra.Command{
		Use:   "monitor",
		Short: "Probe configured targets at interval and append results to daily JSONL files",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load(cfgFile)
			if err != nil {
				return err
			}
			if err := config.Validate(cfg); err != nil {
				return err
			}

			mode, err := monitor.ResolveDisplay(display, term.IsTerminal(int(os.Stdout.Fd())))
			if err != nil {
				return err
			}

			opts := monitor.Options{Display: mode, OutputFile: outputFile}
			if duration != "" {
				d, err := time.ParseDuration(duration)
				if err != nil {
					return fmt.Errorf("error: invalid --duration %q: %w. Use a Go duration string like 30s, 5m, 1h.", duration, err)
				}
				if d <= 0 {
					return fmt.Errorf("error: --duration must be > 0. Got %q.", duration)
				}
				if d < cfg.Interval {
					fmt.Fprintf(os.Stderr, "warning: --duration %s is less than interval %s; may complete 0 cycles\n", d, cfg.Interval)
				}
				opts.Duration = d
			}

			return monitor.Run(cfg, &probe.ICMPProber{}, opts)
		},
	}
	cmd.Flags().StringVar(&duration, "duration", "", "run for this long then exit (e.g. 30s, 5m, 1h)")
	cmd.Flags().StringVar(&display, "display", "log", "terminal output mode: log or chart")
	cmd.Flags().StringVar(&outputFile, "output", "", "write results to this file (default: auto-named daily file in data_dir)")
	return cmd
}

func newReportCmd() *cobra.Command {
	var (
		targetLabel string
		fromStr     string
		toStr       string
		jsonOutput  bool
	)
	cmd := &cobra.Command{
		Use:   "report",
		Short: "Print connectivity history for a target",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load(cfgFile)
			if err != nil {
				return err
			}

			var from, to time.Time
			if fromStr != "" {
				from, err = time.Parse(time.RFC3339, fromStr)
				if err != nil {
					return fmt.Errorf("error: invalid --from %q: not RFC3339. Example: 2026-05-27T00:00:00Z.", fromStr)
				}
			}
			if toStr != "" {
				to, err = time.Parse(time.RFC3339, toStr)
				if err != nil {
					return fmt.Errorf("error: invalid --to %q: not RFC3339. Example: 2026-05-27T23:59:59Z.", toStr)
				}
			}

			records, err := store.ReadResults(cfg.DataDir, targetLabel, from, to)
			if err != nil {
				return fmt.Errorf("error: reading data dir %s: %w.", cfg.DataDir, err)
			}

			rs := report.Summarise(targetLabel, records)
			if jsonOutput {
				return report.FormatJSON(os.Stdout, rs)
			}
			report.FormatTable(os.Stdout, rs)
			return nil
		},
	}
	cmd.Flags().StringVar(&targetLabel, "target", "", "target label to report on (required)")
	_ = cmd.MarkFlagRequired("target")
	cmd.Flags().StringVar(&fromStr, "from", "", "start time filter (RFC3339)")
	cmd.Flags().StringVar(&toStr, "to", "", "end time filter (RFC3339)")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "emit report as JSON")
	return cmd
}

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Println(version)
		},
	}
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
