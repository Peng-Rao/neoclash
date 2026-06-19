# NeoClash

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

## Core Binary

NeoClash bundles an app-owned Mihomo sidecar at `NeoClash/Resources/Core/mihomo`.
The current binary is `mihomo-darwin-arm64-v1.19.27.gz` from `MetaCubeX/mihomo`,
with its extracted SHA-256 recorded in `NeoClash/Resources/Core/mihomo-manifest.json`.

The app also bundles `geoip.dat`, `geosite.dat`, and `country.mmdb` from
`MetaCubeX/meta-rules-dat` under `NeoClash/Resources/Geo/`. During real runtime
startup these files are copied beside the generated Mihomo runtime config so
profiles using `GEOIP`/`GEOSITE` rules can validate and start without a first-run
geodata download.
