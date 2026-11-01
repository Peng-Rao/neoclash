# NeoClash

[![CI](https://github.com/Peng-Rao/neoclash/actions/workflows/ci.yml/badge.svg)](https://github.com/Peng-Rao/neoclash/actions/workflows/ci.yml)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)
![macOS](https://img.shields.io/badge/macOS-26%2B-blue)
![iOS](https://img.shields.io/badge/iOS-26%2B-lightgrey)

NeoClash is a native macOS 26+ SwiftUI proxy client built around an app-owned
Mihomo sidecar process. It keeps the imported profile immutable, generates a
runtime Mihomo config at launch, and controls the core through a loopback-only
API protected by a per-launch secret.

## Features

- Native SwiftUI app shell with dashboard, profile management, proxy groups,
  rules, connections, logs, settings, and Liquid Glass-style surfaces.
- AppKit-backed menu bar popover with runtime controls and proxy group node
  switching.
- Mihomo runtime lifecycle management with config validation, readiness checks,
  process output diagnostics, and crash reporting.
- System proxy mode with snapshot/restore support for macOS network services.
- TUN / enhanced mode support. NeoClash stages a writable copy of the core and
  asks for administrator authorization only when setuid-root privileges are
  missing.
- Runtime config generation for ports, controller secret, mode, DNS, TUN, log
  level, and geodata paths while preserving profile-owned IPv6 and TUN tuning.
- Testable core services exposed through the `NeoClashCore` Swift package.

## Runtime Behavior

On start, NeoClash builds a runtime YAML file from the selected imported profile.
If no profile is selected, it launches Mihomo with a direct-only runtime config.
The external controller is bound to `127.0.0.1` by default and receives a fresh
secret for each launch.

When system proxy mode is enabled, NeoClash snapshots the current macOS proxy
settings before applying its HTTP/SOCKS proxy configuration, then restores the
snapshot when proxy mode or the runtime is stopped.

When TUN mode is enabled, NeoClash restarts a running core so the generated
runtime config and core privileges match the selected mode.

## Build

The core and app sources are available as a Swift package.

```sh
swift test
swift build
```

The repository also includes `project.yml` for XcodeGen. Generate the Xcode project with:

```sh
xcodegen generate
```

`xcodegen` is not vendored in this repository.

## iOS Target

iOS cannot launch a child process, so mihomo is linked in as a library. `core/mobile`
wraps it in a small C API, and `scripts/build-ios-core.sh` builds that into
`core/mobile/build/NeoClashEngine.xcframework` (gitignored). The script needs Go and
Xcode, and runs on Apple Silicon only.

There are two app schemes. They share all UI and logic, and differ in where the core runs:

| | `NeoClash iOS Local` | `NeoClash iOS` |
|---|---|---|
| Core runs in | The app | The `NeoClashPacketTunnel` extension |
| Apple account | Free | Paid Developer Program |
| Proxies device traffic | No | Yes |
| Runs in the background | No | Yes |

The Local build is a real core with live proxies, latency tests, connections and logs,
but it does not route the device's traffic, because that takes the Network Extension
capability. It also stops launching after 7 days, when free signing expires.

Build the core, then generate the project:

```sh
./scripts/build-ios-core.sh
xcodegen generate
```

Run in the Simulator from Xcode with the `NeoClash iOS Local` scheme. Packet tunnels do
not run in the Simulator. To install on a connected iPhone:

```sh
xcodebuild -project NeoClash.xcodeproj -scheme "NeoClash iOS Local" -destination 'generic/platform=iOS' -derivedDataPath .build/ios-device -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-id> .build/ios-device/Build/Products/Debug-iphoneos/NeoClashIOSLocal.app
```

On first launch, trust the developer in Settings > General > VPN & Device Management.

### Moving to the VPN build

The tunnel code compiles and links, but it has never run: that needs a paid account and a
real device. After enrolling:

1. Register the `group.com.pengrao.NeoClash` app group and let Xcode manage the
   Network Extension capability for `com.pengrao.NeoClash.iOS` and its
   `.PacketTunnel` extension.
2. Build and install the `NeoClash iOS` scheme on the device.
3. Test with a real profile, and watch the extension's memory. iOS kills packet tunnels at
   a limit reported as 50 MiB, and the core's soft limit in `PacketTunnelProvider` is 38 MiB.

## Core Binary

NeoClash bundles an app-owned Mihomo sidecar at `NeoClash/Resources/Core/mihomo`.
The current binary is `mihomo-darwin-arm64-v1.19.27.gz` from `MetaCubeX/mihomo`,
with its extracted SHA-256 recorded in `NeoClash/Resources/Core/mihomo-manifest.json`.

The app also bundles `geoip.dat`, `geosite.dat`, and `country.mmdb` from
`MetaCubeX/meta-rules-dat` under `NeoClash/Resources/Geo/`. During real runtime
startup these files are copied beside the generated Mihomo runtime config so
profiles using `GEOIP`/`GEOSITE` rules can validate and start without a first-run
geodata download.
