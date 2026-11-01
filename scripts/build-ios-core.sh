#!/usr/bin/env bash
# Builds core/mobile into NeoClashEngine.xcframework (iOS device and Simulator, arm64).
# The output is gitignored; run this before generating or building the iOS targets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT/core/mobile"
BUILD_DIR="$CORE_DIR/build"
OUTPUT="$BUILD_DIR/NeoClashEngine.xcframework"
MIN_IOS="26.0"
MIHOMO_VERSION="$(cd "$CORE_DIR" && go list -m -f '{{.Version}}' github.com/metacubex/mihomo)"

build_slice() {
    local sdk="$1" target="$2" out="$BUILD_DIR/$1"
    local sdk_path clang
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    clang="$(xcrun --sdk "$sdk" --find clang)"
    mkdir -p "$out"

    echo "Building $sdk slice..."
    (
        cd "$CORE_DIR"
        CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
        CC="$clang" CXX="$clang" \
        CGO_CFLAGS="-isysroot $sdk_path -target $target -fembed-bitcode=off" \
        CGO_LDFLAGS="-isysroot $sdk_path -target $target" \
        go build -buildmode=c-archive -tags with_gvisor -trimpath \
            -ldflags "-s -w -X github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION" \
            -o "$out/libneoclashengine.a" .
    )
}

rm -rf "$BUILD_DIR"
build_slice iphoneos "arm64-apple-ios$MIN_IOS"
build_slice iphonesimulator "arm64-apple-ios$MIN_IOS-simulator"

xcodebuild -create-xcframework \
    -library "$BUILD_DIR/iphoneos/libneoclashengine.a" -headers "$CORE_DIR/include" \
    -library "$BUILD_DIR/iphonesimulator/libneoclashengine.a" -headers "$CORE_DIR/include" \
    -output "$OUTPUT"

echo "Built $OUTPUT ($MIHOMO_VERSION)"
