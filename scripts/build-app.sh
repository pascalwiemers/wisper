#!/bin/bash
# Builds Wisper and wraps it into Wisper.app so macOS grants it TCC
# permissions (microphone, accessibility) properly.
#
# Uses xcodebuild (not `swift build`): MLX's GPU kernels are .metal sources
# that only Xcode's build system can compile into the metallib bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -scheme Wisper -configuration Release \
    -destination 'platform=macOS,arch=arm64' ARCHS=arm64 \
    -derivedDataPath .build/xcode -skipPackagePluginValidation -skipMacroValidation build 2>&1 \
    | grep -E "error:|BUILD" || true

PRODUCTS=".build/xcode/Build/Products/Release"
[[ -x "$PRODUCTS/Wisper" ]] || { echo "Build failed — no binary at $PRODUCTS/Wisper"; exit 1; }

APP="build/Wisper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Wisper" "$APP/Contents/MacOS/Wisper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Resource bundles (MLX metallib, FluidAudio resources, tokenizer data).
# Bundle.module resolves against the main bundle's Resources directory.
for bundle in "$PRODUCTS"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Prefer a real signing identity: it keeps the app's identity stable across
# rebuilds, so TCC grants (Accessibility) survive. Ad-hoc is the fallback,
# where every rebuild changes the hash and macOS drops the grants.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

# --install: replace the copy in /Applications and relaunch it.
if [[ "${2:-}" == "--install" || "${1:-}" == "--install" ]]; then
    pkill -x Wisper 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Wisper.app
    ditto "$APP" /Applications/Wisper.app
    open /Applications/Wisper.app
    echo "Installed and relaunched /Applications/Wisper.app"
else
    echo "Run with: open $APP   (or: $0 --install)"
fi
