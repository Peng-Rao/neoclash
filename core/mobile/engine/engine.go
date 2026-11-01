// Package engine runs mihomo inside the host process. iOS cannot spawn a binary, so the app and
// the packet tunnel extension drive the core through this package instead of a subprocess.
package engine

import (
	"errors"
	"fmt"
	"os"
	"runtime/debug"
	"sync"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// idleConfig has no listeners or controller. Applying it is what releases the ports:
// executor.Shutdown only closes the TUN listener, which is enough for a process about to exit
// but not for one that keeps running.
const idleConfig = "mode: direct\nlog-level: silent\ngeodata-mode: false\n"

// iOS extensions have a small hard memory ceiling, so collect sooner than Go's default.
const constrainedGCPercent = 50

var (
	mu      sync.Mutex
	running bool
)

// Options configures a Start call.
type Options struct {
	HomeDir    string
	ConfigPath string
	// TunFD is an existing utun descriptor from NEPacketTunnelProvider, or 0 for no TUN device.
	TunFD int
	// MemoryLimit is a soft Go runtime limit in bytes, or 0 to leave the runtime defaults.
	MemoryLimit int64
}

// Start loads the config and brings the core up. The controller listens asynchronously, so
// callers should poll it before assuming it is ready.
func Start(options Options) error {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return errors.New("core is already running")
	}

	configBytes, err := os.ReadFile(options.ConfigPath)
	if err != nil {
		return fmt.Errorf("read config: %w", err)
	}

	route.SetEmbedMode(true)
	C.SetHomeDir(options.HomeDir)
	if options.MemoryLimit > 0 {
		debug.SetMemoryLimit(options.MemoryLimit)
		debug.SetGCPercent(constrainedGCPercent)
	}

	cfg, err := executor.ParseWithBytes(configBytes)
	if err != nil {
		return fmt.Errorf("parse config: %w", err)
	}
	if options.TunFD > 0 {
		cfg.General.Tun.Enable = true
		cfg.General.Tun.FileDescriptor = options.TunFD
	}

	hub.ApplyConfig(cfg)
	running = true
	return nil
}

// Stop closes live connections, listeners and the controller. It is safe to call when stopped.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if !running {
		return nil
	}

	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})

	cfg, err := config.Parse([]byte(idleConfig))
	if err != nil {
		return fmt.Errorf("parse idle config: %w", err)
	}
	hub.ApplyConfig(cfg)
	executor.Shutdown()
	running = false
	return nil
}

// Version returns the embedded mihomo version.
func Version() string {
	return C.Version
}
