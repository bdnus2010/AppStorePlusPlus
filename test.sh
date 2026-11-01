#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_APP="$PWD/build/EngineTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources/Tools" build/module-cache
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$PWD/build/module-cache" -framework SwiftUI -framework AppKit \
    Sources/Donation.swift Sources/Engine.swift Tests/EngineTests.swift -o "$TEST_APP/Contents/MacOS/EngineTests"
cp Tests/mock-ipatool.py "$TEST_APP/Contents/Resources/Tools/ipatool"
cp Tests/mock-unfairplay.py "$TEST_APP/Contents/Resources/Tools/unfairplay"
chmod +x "$TEST_APP/Contents/Resources/Tools/ipatool" "$TEST_APP/Contents/Resources/Tools/unfairplay"
python3 Tests/create-fixtures.py
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>EngineTests</string><key>CFBundleIdentifier</key><string>local.appstoreplusplus.engine-tests</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
"$TEST_APP/Contents/MacOS/EngineTests"
