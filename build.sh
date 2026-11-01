#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
GO="$ROOT/.toolchain/go/bin/go"
if [[ ! -x "$GO" ]]; then GO="$(command -v go)"; fi
mkdir -p build/bin build/module-cache dist Resources/AppIcon.iconset
export GOCACHE="$ROOT/build/go-cache"
export GOPATH="$ROOT/build/go-path"
export GOMODCACHE="$ROOT/build/go-modules"
if [[ "${SKIP_GO:-0}" != "1" ]]; then
    (cd vendor/ipatool && "$GO" build -trimpath -o "$ROOT/build/bin/ipatool" .)
    (cd vendor/unfairplay && "$GO" build -trimpath -o "$ROOT/build/bin/unfairplay" ./cmd/unfairplay)
fi
APP="$ROOT/dist/AppStore++.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Tools" "$APP/Contents/Resources/Licenses"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$ROOT/build/module-cache" -framework SwiftUI -framework AppKit \
    Sources/Donation.swift Sources/Engine.swift Sources/App.swift -o "$APP/Contents/MacOS/AppStorePlusPlus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/TigerCookie.png "$APP/Contents/Resources/TigerCookie.png"
cp Resources/BuyMeACoffee.png "$APP/Contents/Resources/BuyMeACoffee.png"
cp Resources/BuyMeACoffee-logo.svg "$APP/Contents/Resources/BuyMeACoffee-logo.svg"
cp Resources/BuyMeACoffee-NOTICE.txt "$APP/Contents/Resources/Licenses/BuyMeACoffee-NOTICE.txt"
cp Resources/EngineVersions.txt "$APP/Contents/Resources/EngineVersions.txt"
cp build/bin/ipatool build/bin/unfairplay "$APP/Contents/Resources/Tools/"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/TigerCookie.png --out "Resources/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/TigerCookie.png --out "Resources/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp vendor/ipatool/LICENSE "$APP/Contents/Resources/Licenses/ipatool-MIT.txt"
cp vendor/unfairplay/LICENSE "$APP/Contents/Resources/Licenses/unfairplay-MIT.txt"
cp vendor/unfairplay/LICENSE-DARKPHOENIX.txt "$APP/Contents/Resources/Licenses/DarkPhoenix-Apache-2.0.txt"
cp vendor/unfairplay/NOTICE "$APP/Contents/Resources/Licenses/UnfairPlay-NOTICE.txt"
cp Resources/Icon-prompt.txt "$APP/Contents/Resources/Licenses/Icon-prompt.txt"
python3 bundle_licenses.py
cp README.md VALIDATION.md "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/Resources/Tools/ipatool"
codesign --force --sign - "$APP/Contents/Resources/Tools/unfairplay"
codesign --force --options runtime --sign "${APPSTORE_SIGNING_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/AppStore++-AppleSilicon.zip"
echo "Built: $APP"
