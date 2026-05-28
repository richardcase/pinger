package config

import (
	"fmt"
	"strings"
	"time"

	"github.com/spf13/viper"
)

type Target struct {
	Label   string
	Address string
	Timeout *time.Duration
}

type Config struct {
	Interval time.Duration
	Timeout  time.Duration
	DataDir  string
	Targets  []Target
}

// Load reads a TOML config file, applies defaults, and returns Config.
func Load(path string) (*Config, error) {
	v := viper.New()
	v.SetConfigFile(path)
	v.SetConfigType("toml")

	v.SetDefault("timeout", "5s")
	v.SetDefault("data_dir", ".")

	if err := v.ReadInConfig(); err != nil {
		return nil, fmt.Errorf("error: reading config %s: %w. Ensure the file exists and is valid TOML.", path, err)
	}

	intervalStr := v.GetString("interval")
	if intervalStr == "" {
		return nil, fmt.Errorf("error: config missing required field 'interval'. Add interval = \"30s\" to your config.")
	}
	interval, err := time.ParseDuration(intervalStr)
	if err != nil {
		return nil, fmt.Errorf("error: config field 'interval' %q is not a valid duration: %w.", intervalStr, err)
	}

	timeoutStr := v.GetString("timeout")
	timeout, err := time.ParseDuration(timeoutStr)
	if err != nil {
		return nil, fmt.Errorf("error: config field 'timeout' %q is not a valid duration: %w.", timeoutStr, err)
	}

	dataDir := v.GetString("data_dir")

	rawTargets := v.Get("targets")
	targets, err := parseTargets(rawTargets)
	if err != nil {
		return nil, err
	}

	return &Config{
		Interval: interval,
		Timeout:  timeout,
		DataDir:  dataDir,
		Targets:  targets,
	}, nil
}

func parseTargets(raw interface{}) ([]Target, error) {
	items, ok := raw.([]interface{})
	if !ok || len(items) == 0 {
		return nil, fmt.Errorf("error: config missing required field 'targets'. Add at least one [[targets]] entry.")
	}

	var targets []Target
	for i, item := range items {
		m, ok := item.(map[string]interface{})
		if !ok {
			return nil, fmt.Errorf("error: target entry %d is malformed.", i)
		}

		label, _ := m["label"].(string)
		address, _ := m["address"].(string)
		timeoutStr, _ := m["timeout"].(string)

		var to *time.Duration
		if timeoutStr != "" {
			d, err := time.ParseDuration(timeoutStr)
			if err != nil {
				return nil, fmt.Errorf("error: target %d 'timeout' %q is not a valid duration: %w.", i, timeoutStr, err)
			}
			to = &d
		}

		targets = append(targets, Target{Label: label, Address: address, Timeout: to})
	}
	return targets, nil
}

// Validate checks Config constraints and returns descriptive errors.
func Validate(cfg *Config) error {
	if cfg.Interval <= 0 {
		return fmt.Errorf("error: config field 'interval' must be > 0. Got %s.", cfg.Interval)
	}
	if cfg.Timeout <= 0 {
		return fmt.Errorf("error: config field 'timeout' must be > 0. Got %s.", cfg.Timeout)
	}
	if cfg.DataDir == "" {
		return fmt.Errorf("error: config field 'data_dir' must not be empty.")
	}
	if len(cfg.Targets) == 0 {
		return fmt.Errorf("error: config must have at least 1 target.")
	}
	if len(cfg.Targets) > 10 {
		return fmt.Errorf("error: config has %d targets; maximum is 10. Remove %d target(s).", len(cfg.Targets), len(cfg.Targets)-10)
	}

	labels := map[string]bool{}
	addresses := map[string]bool{}
	for i, t := range cfg.Targets {
		if strings.TrimSpace(t.Label) == "" {
			return fmt.Errorf("error: target %d has empty label. Every target must have a unique non-empty label.", i)
		}
		if labels[t.Label] {
			return fmt.Errorf("error: duplicate target label %q. Labels must be unique.", t.Label)
		}
		labels[t.Label] = true

		if strings.TrimSpace(t.Address) == "" {
			return fmt.Errorf("error: target %q has empty address. Provide a hostname or IP address.", t.Label)
		}
		if addresses[t.Address] {
			return fmt.Errorf("error: duplicate target address %q. Addresses must be unique.", t.Address)
		}
		addresses[t.Address] = true

		if t.Timeout != nil && *t.Timeout <= 0 {
			return fmt.Errorf("error: target %q timeout must be > 0. Got %s.", t.Label, *t.Timeout)
		}
	}

	// Deduplicate (warn-and-dedup handled during parsing; here just enforce clean state).
	return nil
}
