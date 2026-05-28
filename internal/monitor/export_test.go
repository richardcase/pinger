package monitor

import (
	"io"

	"github.com/richardcase/pinger/internal/config"
	"github.com/richardcase/pinger/internal/probe"
)

// RunWithWriter exposes the internal run seam to the external test package,
// injecting the console writer and a fixed terminal size so chart-mode runs
// stay deterministic and terminal-free.
func RunWithWriter(cfg *config.Config, prober probe.Prober, opts Options, out io.Writer, width, height int) error {
	return run(cfg, prober, opts, out, func() (int, int) { return width, height })
}
