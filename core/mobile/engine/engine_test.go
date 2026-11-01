package engine

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	testMixedPort      = 27897
	testControllerPort = 29097
	testSecret         = "engine-test-secret"
)

func writeConfig(t *testing.T) (homeDir, configPath string) {
	t.Helper()
	homeDir = t.TempDir()
	configPath = filepath.Join(homeDir, "config.yaml")
	contents := fmt.Sprintf(`mixed-port: %d
external-controller: 127.0.0.1:%d
secret: %s
mode: rule
log-level: silent
proxies: []
rules:
  - MATCH,DIRECT
`, testMixedPort, testControllerPort, testSecret)
	if err := os.WriteFile(configPath, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return homeDir, configPath
}

func waitForPort(t *testing.T, port int, wantOpen bool) {
	t.Helper()
	address := fmt.Sprintf("127.0.0.1:%d", port)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", address, 200*time.Millisecond)
		if err == nil {
			conn.Close()
		}
		if (err == nil) == wantOpen {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("port %d: wanted open=%v after 5s", port, wantOpen)
}

func TestStartServesControllerWithSecret(t *testing.T) {
	homeDir, configPath := writeConfig(t)
	if err := Start(Options{HomeDir: homeDir, ConfigPath: configPath}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = Stop() })
	waitForPort(t, testControllerPort, true)

	url := fmt.Sprintf("http://127.0.0.1:%d/version", testControllerPort)
	unauthorized, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	unauthorized.Body.Close()
	if unauthorized.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no secret: got status %d", unauthorized.StatusCode)
	}

	request, _ := http.NewRequest(http.MethodGet, url, nil)
	request.Header.Set("Authorization", "Bearer "+testSecret)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), "version") {
		t.Fatalf("status %d, body %s", response.StatusCode, body)
	}
}

func TestStopReleasesPortsAndAllowsRestart(t *testing.T) {
	homeDir, configPath := writeConfig(t)
	for cycle := 0; cycle < 3; cycle++ {
		if err := Start(Options{HomeDir: homeDir, ConfigPath: configPath}); err != nil {
			t.Fatalf("cycle %d start: %v", cycle, err)
		}
		waitForPort(t, testControllerPort, true)
		waitForPort(t, testMixedPort, true)

		if err := Stop(); err != nil {
			t.Fatalf("cycle %d stop: %v", cycle, err)
		}
		waitForPort(t, testControllerPort, false)
		waitForPort(t, testMixedPort, false)
	}
}

func TestStartTwiceFails(t *testing.T) {
	homeDir, configPath := writeConfig(t)
	if err := Start(Options{HomeDir: homeDir, ConfigPath: configPath}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = Stop() })
	if err := Start(Options{HomeDir: homeDir, ConfigPath: configPath}); err == nil {
		t.Fatal("second Start should fail while running")
	}
}

func TestInvalidConfigLeavesCoreStopped(t *testing.T) {
	homeDir := t.TempDir()
	configPath := filepath.Join(homeDir, "config.yaml")
	if err := os.WriteFile(configPath, []byte("rules: [unterminated"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Start(Options{HomeDir: homeDir, ConfigPath: configPath}); err == nil {
		t.Fatal("invalid config should fail")
	}
	_, validPath := writeConfig(t)
	if err := Start(Options{HomeDir: homeDir, ConfigPath: validPath}); err != nil {
		t.Fatalf("start after failure: %v", err)
	}
	t.Cleanup(func() { _ = Stop() })
}
