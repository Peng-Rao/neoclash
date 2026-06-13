# NeoClash

NeoClash is a native macOS 26+ SwiftUI proxy client inspired by Clash/Mihomo desktop clients. It is built as a native control plane around an app-owned Mihomo sidecar process.

The implementation follows the specification in [swiftui-clash-like-proxy-client-implementation.md](swiftui-clash-like-proxy-client-implementation.md):

- Native SwiftUI app shell with `NavigationSplitView`, menu bar controls, settings, and Liquid Glass surfaces.
- Immutable imported profiles and generated runtime Mihomo YAML.
- Per-launch controller secret and loopback-only control API by default.
- Defensive core-process validation/readiness/diagnostics path.
- System proxy command construction with snapshot/restore support.
- Testable core services in a Swift package.

## Build

The core and app sources are available as a Swift package:

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
