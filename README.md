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

The MVP expects an app-owned Mihomo binary at `NeoClash/Resources/Core/mihomo` and geodata under `NeoClash/Resources/Geo/`. These files are intentionally ignored until a verified release artifact and manifest are added.

