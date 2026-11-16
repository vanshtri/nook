#!/bin/bash
# Builds Nook.app into ./build (no Xcode needed, just the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Nook.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Nook "$APP/Contents/MacOS/Nook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# macOS ties Accessibility / Screen Recording grants to the app's "designated requirement".
# Plain ad-hoc signing uses the build's hash, which changes on every rebuild, so permissions
# would silently stop matching. Pinning the requirement to the bundle identifier keeps the
# same grant valid across rebuilds. (Set NOOK_SIGN_ID to use a real certificate instead.)
if [[ -n "${NOOK_SIGN_ID:-}" ]]; then
    codesign --force --sign "$NOOK_SIGN_ID" "$APP" >/dev/null
else
    codesign --force --sign - -r='designated => identifier "dev.local.nook"' "$APP" >/dev/null
fi
if [[ "${1:-}" == "--install" ]]; then
    pkill -x Nook || true
    rm -rf /Applications/Nook.app && cp -R "$APP" /Applications/
    open /Applications/Nook.app
    echo "Installed /Applications/Nook.app"
else
    echo "Built $APP  ->  open $APP   (or ./build.sh --install)"
fi
