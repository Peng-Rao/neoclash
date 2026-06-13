# SwiftUI Clash-like Proxy Client Implementation Brief

This document summarizes open-source/reference implementations of SwiftUI/macOS proxy clients similar to Clash, then proposes a concrete implementation plan for a high-performance, stable native macOS client. It is written as an AI-ready specification: you can paste this file into another coding agent and ask it to build the app.

## Goal

Build a native macOS 26+ proxy client with a Clash/Clash Verge-like experience:

- Native SwiftUI UI using macOS 26+ SwiftUI features, not Electron/WebView.
- Modern Liquid Glass-style interface using current SwiftUI materials/effects where appropriate.
- High-performance, stable proxy core.
- Clash/Mihomo YAML subscription support.
- System proxy mode and TUN/enhanced mode.
- Real-time traffic, logs, connections, proxy groups, rules, and delay tests.
- Safe local control API integration with a per-run secret.
- Stable process lifecycle management, crash diagnostics, and state restoration.

Required target: **macOS 26 and later only**. Do not spend engineering effort on backward compatibility with older macOS releases. iOS support should be a separate product track because iOS requires NetworkExtension entitlements and cannot simply launch a sidecar core process like a normal macOS app.

---

## Researched References

### 1. LiquidClash

Repository: <https://github.com/liquidclash/liquidclash>

Observed implementation characteristics from the cloned repository:

- Native SwiftUI macOS app.
- Requires macOS 26+ and Swift 6.2.
- Bundles `mihomo`, `country.mmdb`, `geoip.dat`, and `geosite.dat` under app resources.
- Core project structure:
  - `LiquidClashApp.swift`: app entry and menu bar integration.
  - `Core/ClashAPI.swift`: Clash/Mihomo REST API client.
  - `Core/ClashManager.swift`: core process lifecycle via helper daemon.
  - `Core/ClashWebSocket.swift`: real-time updates.
  - `Core/SystemProxy.swift`: macOS `networksetup` system proxy management.
  - `Core/ConfigPipeline.swift`: runtime config generation.
  - `Services/SubscriptionManager.swift`: subscription import/update.
  - `Services/ConfigStorage.swift`: app support persistence.
  - `Views/`: dashboard, proxies, logs, rules, settings, menu bar.
- Useful ideas:
  - Keep UI fully native and light.
  - Use Mihomo REST endpoints for proxy groups, rules, connections, logs, traffic, and mode changes.
  - Copy bundled geodata into the runtime config directory before starting the core.
  - Snapshot and restore macOS proxy settings instead of blindly turning proxy off.
- Weaknesses/risks to improve:
  - The public README claims MIT, but GitHub API did not expose a license object at time of research; verify license before copying code.
  - More robust process readiness, port conflict checks, config validation, and test coverage should be added.

### 2. ClashMax

Repository: <https://github.com/marvinli001/ClashMax>

Observed implementation characteristics from the cloned repository:

- Native SwiftUI macOS Mihomo client.
- GPL-3.0 license.
- Requires macOS 26+.
- Uses XcodeGen (`project.yml`) and a broad test suite.
- Bundles a stable Mihomo core and treats it as an app-owned sidecar.
- Key implementation ideas:
  - Preserve imported YAML unchanged.
  - Generate a managed runtime YAML before launch.
  - Inject `mixed-port`, `external-controller`, `secret`, DNS, TUN, mode, log level, and overrides into the runtime YAML.
  - Store subscription URLs in Keychain by profile ID.
  - Generate a new controller secret for every launch.
  - Bind the controller to `127.0.0.1` by default.
  - Validate config with the core before launch.
  - Check runtime ports before launch.
  - Reap stale app-managed Mihomo processes.
  - Wait for `/version` readiness before declaring the core running.
  - Capture process output tails for startup diagnostics.
  - Use tests for API client, config normalizer, system proxy, NetworkExtension config, runtime paths, subscriptions, and migration parsing.
- Useful files/patterns:
  - `Services/CoreProcessController.swift`: robust start/stop/readiness/crash handling.
  - `Services/ConfigNormalizer.swift`: runtime YAML generation and override injection.
  - `Stores/SystemProxyCoordinator.swift`: system proxy state coordination.
  - `ClashMaxNetworkExtension/TransparentProxyProvider.swift`: experimental Network Extension/TUN path.
  - `Config/*.entitlements`, helper plists, and tests around helper/service identity.
- Recommendation: use ClashMax as the strongest architectural reference, but do not copy GPL code into a non-GPL project unless the target project is GPL-compatible.

### 3. iClash

Repository: <https://github.com/JustCod101/iClash>

Observed implementation characteristics from the cloned repository:

- SwiftUI app targeting iOS 15+ and macOS 12+.
- Has app views, config manager, proxy manager, and a `NetworkExtension/PacketTunnelProvider.swift`.
- The PacketTunnelProvider is mostly a placeholder:
  - Uses static DNS servers.
  - Defines included default IPv4 route.
  - Logs that it “would start Clash core”.
  - Uses a stub `ClashProcessManager` instead of a real core integration.
- Useful ideas:
  - The repository shows the high-level shape of an iOS/macOS SwiftUI + NetworkExtension app.
- Weaknesses:
  - Not production-ready for a real high-performance client.
  - Does not implement real core process embedding, packet forwarding, config validation, or subscription handling deeply enough.

### 4. ClashMac

Repository: <https://github.com/666OS/ClashMac>

Observed implementation characteristics:

- Native macOS menu bar proxy client using Mihomo.
- Strong product ideas:
  - Menu-bar-first lightweight client.
  - System proxy + TUN enhanced mode.
  - Live traffic, connection topology, route map, rule statistics.
  - Subscription import, drag-and-drop YAML, config pre-checks.
  - Auto-disconnect existing connections after node switch.
  - Privileged helper with path whitelist and command-injection hardening.
- Important limitation:
  - The repository states it is proprietary/closed-source and only binary releases are provided. Treat it as product/UX inspiration only, not code reference.

### 5. Mihomo core and docs

Relevant docs: <https://wiki.metacubex.one/en/config/general>

Important facts:

- Mihomo exposes a REST/WebSocket control plane through `external-controller`.
- Recommended secure default: bind to `127.0.0.1`, not `0.0.0.0`.
- Use a non-empty controller password and send it in the standard Bearer authorization header.
- Useful endpoints/patterns:
  - `GET /version`
  - `GET /configs`, `PATCH /configs`, `PUT /configs?force=true`
  - `GET /proxies`
  - `PUT /proxies/{group}` with `{ "name": "proxy" }`
  - `GET /proxies/{name}/delay?url=...&timeout=...`
  - `GET /connections`, `DELETE /connections`, `DELETE /connections/{id}`
  - WebSocket streams for traffic/logs/connections, depending on Mihomo build.
- `external-controller-unix` exists, but Unix socket APIs may not validate secrets; if used, protect filesystem permissions carefully.

### 6. sing-box

Relevant docs: <https://sing-box.sagernet.org/manual/proxy/client/> and <https://sing-box.sagernet.org/installation/package-manager>

Important facts:

- sing-box is a high-performance universal proxy platform with strong TUN/transparent proxy support.
- It supports many modern protocols and is excellent for custom native clients.
- However, Clash/Mihomo YAML compatibility and Clash-style proxy-group UX are not its native model.
- For a Clash-like GUI with broad existing subscription compatibility, **Mihomo is the better first core**.
- Consider sing-box later as a second core only after a stable core abstraction layer exists.

---

## Core Recommendation

Use **Mihomo** as the primary embedded core.

Reasoning:

- Best compatibility with Clash/Clash Meta subscriptions and YAML profiles.
- Mature REST/WebSocket control API for GUI clients.
- Supports the expected Clash-like UX: proxy groups, rules, providers, mode switching, delay tests, connections, logs.
- Supports modern protocols commonly expected by users: Shadowsocks, VMess, VLESS, Trojan, Hysteria2, TUIC, WireGuard, SOCKS, HTTP, etc., depending on build.
- Easier to implement a stable client because the UI can treat Mihomo as a sidecar process with a local admin API.

Do **not** start by writing your own proxy engine. The app should be a native control plane, profile manager, and system integration layer around a proven core.

Optional future direction:

- Add a `ProxyCoreAdapter` protocol and implement a second `SingBoxAdapter` later.
- Do not block the MVP on dual-core support.

---

## Proposed Architecture

### High-level components

```text
SwiftUI App
├── AppState / RuntimeStore
├── ProfileStore
├── SubscriptionService
├── RuntimeConfigBuilder
├── CoreProcessController
├── MihomoAPIClient
├── MihomoWebSocketClient
├── SystemProxyController
├── TUNController / PrivilegedHelperClient
├── KeychainStore
├── SecurePathValidator
├── DiagnosticsStore
└── SwiftUI Views
    ├── Dashboard
    ├── Profiles
    ├── Proxies
    ├── Connections
    ├── Rules
    ├── Logs
    ├── Settings
    └── MenuBar Panel
```

### Runtime data flow

```text
User imports subscription/YAML
        ↓
ProfileStore saves original profile unchanged
        ↓
RuntimeConfigBuilder generates app-managed runtime config
        ↓
CoreProcessController validates config and launches Mihomo
        ↓
Mihomo binds mixed-port and external-controller on localhost
        ↓
MihomoAPIClient + WebSocketClient feed RuntimeStore
        ↓
SwiftUI views update live
        ↓
SystemProxyController or TUNController captures system traffic
```

---

## Concrete Implementation Specification

### 1. Project setup

Use a native macOS 26+ SwiftUI app.

Recommended minimum:

- macOS 26.0+ deployment target.
- Xcode 26.0+.
- Swift 6.2 or newer.
- Use the newest SwiftUI APIs available on macOS 26 instead of older compatibility workarounds.
- Prefer native macOS 26 visual language: Liquid Glass-style surfaces, modern materials, mesh gradients, smooth transitions, and native sidebar/toolbar/window behaviors.
- XcodeGen for reproducible project generation.
- Swift Package dependencies:
  - `Yams` for YAML parsing and generation.
  - `Sparkle` for app updates, if distributing outside App Store.
  - Optional: a small Keychain wrapper, or write a direct Security.framework wrapper.

Suggested layout:

```text
ProxyClient/
├── App/
├── Models/
├── Stores/
├── Services/
├── Core/
├── Helpers/
├── Resources/Core/
├── Resources/Geo/
├── Views/
├── Tests/
└── project.yml
```

### 2. Core binary policy

Bundle a known stable Mihomo binary inside the app or download it through a verified update channel.

MVP policy:

- Bundle exactly one app-owned Mihomo binary.
- Do not execute arbitrary user-selected core paths in the MVP.
- Store a manifest such as:

```json
{
  "name": "mihomo",
  "version": "v1.x.y",
  "arch": "arm64",
  "sha256": "...",
  "source": "https://github.com/MetaCubeX/..."
}
```

Startup checks:

- Verify the binary exists.
- Verify it is executable.
- Verify SHA-256 against the manifest.
- Verify architecture matches current machine if shipping separate Intel/ARM builds.
- Refuse to launch if validation fails.

Future update channel:

- Download to an app-managed cache.
- Verify signature or SHA-256 from a trusted manifest.
- Keep previous working core for rollback.
- Only allow helper execution from app-owned, validated paths.

### 3. Runtime directories

Use Application Support, not random temp paths.

Example paths:

```text
~/Library/Application Support/<BundleID>/
├── Profiles/
│   ├── <profile-id>/original.yaml
│   └── <profile-id>/provider.yaml
├── Runtime/
│   ├── config.yaml
│   ├── country.mmdb
│   ├── geoip.dat
│   └── geosite.dat
├── Logs/
└── Cores/
```

Requirements:

- Original profiles must remain unchanged.
- Runtime config is generated and can be overwritten.
- Copy required geodata into the runtime directory before core launch.
- Do not log subscription URLs or node credentials.

### 4. Profile and subscription management

Implement `ProfileStore`:

```swift
struct ProxyProfile: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var kind: ProfileKind
    var localFileURL: URL
    var lastUpdatedAt: Date?
    var createdAt: Date
}

enum ProfileKind: Codable, Sendable {
    case localYAML
    case remoteSubscription
}
```

Subscription URL storage:

- Store the URL in Keychain keyed by profile ID.
- Never store subscription URLs in plaintext UserDefaults.
- Redact URLs in logs and diagnostics.

Subscription update behavior:

- Fetch with `URLSession` using explicit timeout.
- Respect redirects but cap redirect count.
- Reject extremely large responses unless user confirms.
- Validate YAML before replacing the profile file.
- Keep the last known good profile on update failure.

### 5. Runtime config generation

Implement `RuntimeConfigBuilder`.

Inputs:

- Original Clash/Mihomo YAML profile.
- User runtime overrides.
- Current selected profile.
- TUN settings.
- System proxy settings.
- API host/port/secret.

Always inject or normalize:

```yaml
mixed-port: 7897
external-controller: 127.0.0.1:9097
secret: "<random-per-launch-secret>"
allow-lan: false
mode: rule
log-level: info
ipv6: true
unified-delay: true
```

If TUN is enabled, inject:

```yaml
tun:
  enable: true
  stack: system
  device: utun
  auto-route: true
  strict-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
  mtu: 9000
```

For macOS, avoid Linux-only settings such as `auto-redirect`.

DNS recommendations:

```yaml
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  fallback:
    - https://dns.google/dns-query
```

Important safeguards:

- Force `external-controller` to loopback unless the user explicitly enables external control.
- Require a non-empty secret.
- Validate that selected ports are not already occupied.
- Keep user profile rules/proxies/providers intact unless an override is explicitly enabled.
- Do not mutate imported profiles; write only generated runtime YAML.

### 6. Core process lifecycle

Implement `CoreProcessController` as the most defensive component.

Start sequence:

1. Stop any currently running app-managed core.
2. Validate core binary.
3. Generate runtime YAML.
4. Run Mihomo config validation if supported by the binary.
5. Check required ports: `mixed-port`, `external-controller`.
6. Reap stale app-managed Mihomo processes only if they match app-owned paths.
7. Launch process:

```swift
process.executableURL = coreURL
process.arguments = ["-f", runtimeConfigURL.path, "-d", runtimeDirectory.path]
process.currentDirectoryURL = runtimeDirectory
process.environment = [
    "SAFE_PATHS": runtimeDirectory.path
]
```

8. Capture stdout/stderr into a bounded ring buffer.
9. Poll `GET /version` until ready or timeout.
10. Mark runtime as running only after `/version` succeeds.

Stop sequence:

1. Disable/restore system proxy if app enabled it.
2. Ask the core to stop gracefully if there is a supported API.
3. Send `terminate()`.
4. Wait a short grace period.
5. Escalate to `kill()` if needed.
6. Clear runtime state.

Crash behavior:

- If process exits unexpectedly, mark status as crashed.
- Store the last 4–8 KB of output as diagnostics.
- Show a user-readable error and a “Copy Diagnostics” button.

### 7. Mihomo API client

Implement an actor-based API client.

```swift
actor MihomoAPIClient {
    let baseURL: URL
    let secret: String
    let session: URLSession

    init(host: String, port: Int, secret: String) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.secret = secret
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: config)
    }
}
```

Required methods:

- `version()`
- `configs()`
- `updateMode(_:)`
- `reloadConfig(path:)`
- `proxies()`
- `selectProxy(group:proxy:)`
- `testDelay(name:url:timeout:)`
- `rules()`
- `connections()`
- `closeConnection(id:)`
- `closeAllConnections()`
- `providers()` and provider health checks if available.

Implementation requirements:

- Always send the standard Bearer authorization header with the runtime controller password.
- Percent-encode path segments such as proxy/group names.
- Treat delay-test failures as `delay = nil` or `timeout`, not as fatal UI errors.
- Decode unknown JSON defensively because Mihomo API response shapes can vary by version.

### 8. WebSocket streams

Implement WebSocket streams for live data:

- Traffic upload/download speed.
- Core logs.
- Connections, if supported.

Requirements:

- Reconnect with exponential backoff while core is running.
- Stop streams immediately when core stops.
- Backpressure UI updates; do not publish every packet/log line directly to SwiftUI.
- Keep bounded buffers for logs and traffic samples.

### 9. System proxy mode

Implement `SystemProxyController` using `/usr/sbin/networksetup`.

Enable behavior:

- Find active services: prefer `Wi-Fi`, then `Ethernet`, then first available service.
- Snapshot existing HTTP, HTTPS, and SOCKS proxy settings.
- Set bypass domains: `localhost`, `127.0.0.1`, `*.local`.
- Set HTTP and HTTPS proxy to `127.0.0.1:<mixed-port>`.
- Set SOCKS proxy to `127.0.0.1:<mixed-port>` or a dedicated SOCKS port if configured.
- Persist a marker that the app changed the settings.

Disable behavior:

- Restore the snapshot exactly if present.
- If no snapshot exists, turn off only the proxies the app set.
- Always attempt restoration on app termination and core crash.

Do not assume there is only one network service forever. If the user switches from Wi-Fi to Ethernet, re-resolve the service and show status clearly.

### 10. TUN / enhanced mode

For macOS MVP, prefer Mihomo’s built-in TUN support controlled through runtime YAML plus a privileged helper when elevated permissions are needed.

Do **not** implement a fake `NEPacketTunnelProvider` that only sets routes but does not actually forward packets. That pattern appears in simple demos but is not production-ready.

Recommended phases:

#### Phase A: User-mode system proxy

- Ship first with system proxy mode.
- It is simpler, stable, and does not require helper approval for basic use.

#### Phase B: Privileged helper for TUN and system-level operations

- Add a helper with `SMAppService` or the appropriate modern macOS privileged helper mechanism.
- Helper responsibilities:
  - Start/stop app-owned Mihomo with TUN settings if root is required.
  - Perform privileged `networksetup` only if needed.
  - Validate all paths against an app-owned allowlist.
  - Reject shell metacharacters and never invoke `/bin/sh -c` with user-controlled strings.
  - Expose a narrow XPC interface.

#### Phase C: Network Extension only if required

Use NetworkExtension only if:

- You want App Store-compatible VPN-like behavior.
- You target iOS.
- You are prepared to implement real packet forwarding and obtain entitlements.

### 11. Privileged helper security

The helper must be treated as a security boundary.

Requirements:

- Only execute binaries under the signed app bundle or validated app support core directory.
- Verify code signature or SHA-256 before executing.
- Only accept config paths under the app-managed runtime directory.
- Do not accept arbitrary arguments from the UI.
- Use structured XPC messages, not shell commands.
- Refuse relative paths, symlinks escaping the allowed root, and path traversal.
- Log minimal diagnostics without secrets.

Example helper command model:

```swift
enum HelperCommand: Codable {
    case startCore(corePath: String, configPath: String, workDirectory: String)
    case stopCore
    case enableSystemProxy(service: String, host: String, port: Int)
    case restoreSystemProxy(snapshotID: UUID)
}
```

### 12. State management

Use a single main runtime store, e.g. `RuntimeStore`, as the source of truth.

```swift
@MainActor
@Observable
final class RuntimeStore {
    var status: CoreStatus = .stopped
    var activeProfile: ProxyProfile?
    var proxies: [ProxyGroup] = []
    var connections: [Connection] = []
    var traffic: TrafficSnapshot = .zero
    var logs: [CoreLogEntry] = []
    var mode: RoutingMode = .rule
}
```

Rules:

- API/WebSocket clients run off the main actor.
- Publish coalesced updates to the main actor.
- Keep UI responsive during subscription updates and delay tests.
- Do not let view code launch processes directly; views call store/service intents.

### 13. UI specification

Use native SwiftUI with a clear Clash-like structure and a macOS 26-first visual system. The UI should intentionally use new SwiftUI/macOS 26 capabilities instead of limiting itself to older macOS compatibility.

macOS 26 SwiftUI design requirements:

- Use Liquid Glass-style translucent surfaces for the main shell, cards, popovers, and menu bar panel where it improves clarity.
- Use `NavigationSplitView` for the main window with native sidebar behavior.
- Use modern SwiftUI observation/state patterns (`@Observable` / `@State` / environment injection as appropriate) instead of legacy compatibility patterns unless a specific API requires `ObservableObject`.
- Use `MeshGradient`, material backgrounds, symbol effects, smooth transitions, and animated status changes for a polished native feel.
- Use `.glassEffect` or the current macOS 26 glass/material API where available; wrap it in a small view modifier only for code organization, not for old-OS fallback.
- Use `@AppStorage` for simple preferences and Keychain for secrets/subscription URLs.
- Prefer native `Commands`, menu bar extras, toolbar items, inspectors, sheets, and settings scenes over custom window hacks.
- Keep visual effects lightweight: do not let gradients, blur, or live animations compete with traffic/log updates.

Main window:

- Sidebar:
  - Dashboard
  - Profiles
  - Proxies
  - Connections
  - Rules
  - Logs
  - Settings
- Toolbar:
  - Start/Stop runtime
  - Current mode selector: Rule / Global / Direct
  - System Proxy toggle
  - TUN toggle
  - Traffic up/down badges

Dashboard:

- Runtime status.
- Active profile.
- Current public IP check.
- Upload/download speed.
- Active connections count.
- Core version.
- Quick actions: restart, reload config, update subscription, copy diagnostics.

Profiles:

- Add subscription URL.
- Import local YAML.
- Update selected subscription.
- Rename/delete profile.
- Show last updated time.
- Never display full subscription URL by default.

Proxies:

- Group list.
- Proxy node cards.
- Current selected node per group.
- Delay test per node and per group.
- Search/filter nodes.
- Auto-close connections after node switch option.

Connections:

- Destination host/IP.
- Rule matched.
- Chain/proxy used.
- Upload/download bytes.
- Process name if available.
- Close one or all connections.

Rules:

- Display rule providers and current rules.
- Search rules.
- Show match counts only if supported or tracked.

Logs:

- Live core logs.
- Filter by level.
- Pause/resume.
- Copy redacted diagnostics.

Menu bar:

- Current status.
- Upload/download speed.
- Start/stop.
- Mode switch.
- Current proxy group quick switch.
- Open main window.

### 14. Stability and performance requirements

- Never block the main thread with process, network, YAML, or file operations.
- Use bounded log buffers.
- Throttle WebSocket traffic updates to e.g. 2–4 UI updates per second.
- Delay tests should run with concurrency limits.
- Profile parsing should happen in a background task.
- Runtime config writes should be atomic: write to temp file, then replace.
- Use last-known-good profile when subscription update fails.
- Keep runtime launch deterministic and diagnosable.

### 15. Testing plan

Minimum unit tests:

- YAML runtime config generation preserves original proxies/groups/rules.
- Runtime overrides inject correct `mixed-port`, controller, secret, DNS, TUN.
- `external-controller` cannot be empty or public unless explicitly allowed.
- Subscription URL redaction.
- Keychain profile URL save/load/delete.
- API client path encoding for group/proxy names containing `/`, spaces, emoji, or non-ASCII characters.
- Delay-test failure is non-fatal.
- System proxy snapshot/restore command construction.
- Port conflict detection.
- Core process controller handles:
  - ready start,
  - validation failure,
  - port conflict,
  - crash before readiness,
  - crash after readiness,
  - stop escalation.
- Helper path validation rejects symlinks/path traversal/arbitrary binaries.

Integration/smoke tests:

- Launch Mihomo with a minimal generated config.
- Wait for `/version`.
- Fetch `/proxies`.
- Stop cleanly.
- Verify no app-managed core process remains.

Manual QA:

- Import valid Clash subscription.
- Import malformed YAML and verify friendly error.
- Start/stop system proxy and confirm system settings restored.
- Switch nodes and verify connections close/re-route if option enabled.
- Enable TUN and test DNS leak behavior.
- Quit app while running and verify cleanup behavior.

---

## MVP Build Order

1. Create a macOS 26+ SwiftUI project and basic Liquid Glass-style shell UI.
2. Add `ProfileStore` with local YAML import.
3. Add `RuntimeConfigBuilder` with fixed ports and per-launch secret.
4. Bundle Mihomo and geodata.
5. Implement `CoreProcessController` with readiness polling.
6. Implement `MihomoAPIClient` for `/version`, `/proxies`, `/configs`, `/connections`.
7. Build Dashboard and Proxies views.
8. Add System Proxy enable/restore.
9. Add subscription fetch/update and Keychain URL storage.
10. Add logs and traffic WebSocket streams.
11. Add delay tests and proxy group switching.
12. Add robust diagnostics and tests.
13. Add TUN support with helper.
14. Add updater and signed release packaging.

---

## Suggested AI Coding Prompt

Use the following prompt to ask an AI coding agent to implement the app:

```text
Build a native macOS 26+ SwiftUI Clash-like proxy client using Mihomo as an embedded sidecar core.

Requirements:

1. Use SwiftUI, Swift Concurrency, and macOS 26+ SwiftUI features. Do not use Electron or WebView for the app UI. Do not maintain compatibility with macOS versions older than 26.
2. Preserve imported Clash/Mihomo YAML profiles unchanged. Generate an app-managed runtime YAML before every launch.
3. Bundle and validate a Mihomo core binary and geodata files. Do not execute arbitrary user-selected binaries in the MVP.
4. Generate a new non-empty controller secret for every runtime launch.
5. Bind Mihomo external-controller to 127.0.0.1 by default.
6. Implement a robust CoreProcessController:
   - validate config before launch,
   - check port conflicts,
   - launch Mihomo with -f <config> -d <runtime-dir>,
   - capture stdout/stderr in a bounded buffer,
   - poll GET /version until ready,
   - handle crash before/after readiness,
   - cleanly terminate and escalate to kill only when necessary.
7. Implement MihomoAPIClient as an actor that always sends the standard Bearer authorization header with the runtime controller password. Include version, configs, proxies, proxy selection, delay tests, rules, connections, close connections, and config reload.
8. Implement WebSocket streams for logs and traffic with throttled UI updates.
9. Implement SystemProxyController using networksetup:
   - snapshot previous HTTP/HTTPS/SOCKS settings,
   - enable HTTP/HTTPS/SOCKS proxies to 127.0.0.1:<mixed-port>,
   - restore exactly on stop/crash/quit.
10. Implement ProfileStore and SubscriptionService:
   - local YAML import,
   - remote subscription add/update,
   - subscription URLs stored in Keychain,
   - last-known-good profile retained on update failure,
   - URLs and node credentials redacted from logs.
11. Build SwiftUI views with a macOS 26-first Liquid Glass-style design system:
   - Dashboard,
   - Profiles,
   - Proxies,
   - Connections,
   - Rules,
   - Logs,
   - Settings,
   - Menu bar panel.
12. Add tests for config generation, API path encoding, process lifecycle, system proxy command generation, subscription redaction, and helper path validation.
13. Add TUN only after system proxy mode is stable. For macOS TUN, use Mihomo TUN runtime config plus a privileged helper with strict path allowlisting. Do not create a fake NetworkExtension that sets routes without real packet forwarding.

Architecture to follow:

SwiftUI App
├── RuntimeStore
├── ProfileStore
├── SubscriptionService
├── RuntimeConfigBuilder
├── CoreProcessController
├── MihomoAPIClient
├── MihomoWebSocketClient
├── SystemProxyController
├── KeychainStore
├── SecurePathValidator
└── SwiftUI Views

Prioritize stability, security, and diagnosability over visual polish. Every start failure should produce a clear user-facing error and a copyable redacted diagnostic bundle.
```

---

## Final Recommendation

For a high-performance and stable client, implement a **native SwiftUI macOS 26+ app around Mihomo**, with a strict runtime-config pipeline and robust process/controller integration. Use LiquidClash for macOS 26 SwiftUI/Liquid Glass UI inspiration, ClashMax for architecture and reliability patterns, ClashMac for UX ideas only, and treat iClash as a conceptual NetworkExtension demo rather than production code.

The most important engineering decisions are:

1. **Mihomo first, sing-box later** through a core adapter abstraction.
2. **Original profile immutable, runtime config generated**.
3. **Local controller secured with per-launch secret**.
4. **System proxy first, TUN after helper/security foundations are solid**.
5. **Defensive lifecycle management and diagnostics from day one**.
