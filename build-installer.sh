#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/dist/AppStore++.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="$ROOT/dist/AppStore++-$VERSION-AppleSilicon.pkg"
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/build" "$ROOT/dist"
STAGING="$(mktemp -d "$ROOT/build/installer.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/root/Applications"
ditto "$APP" "$STAGING/root/Applications/AppStore++.app"
pkgbuild --analyze --root "$STAGING/root" "$STAGING/components.plist"
python3 - "$STAGING/components.plist" <<'PY'
import plistlib
import sys
from pathlib import Path
path = Path(sys.argv[1])
components = plistlib.loads(path.read_bytes())
for component in components:
    component['BundleIsRelocatable'] = False
    component['BundleIsVersionChecked'] = True
    component['BundleHasStrictIdentifier'] = True
    component['BundleOverwriteAction'] = 'upgrade'
path.write_bytes(plistlib.dumps(components))
PY
pkgbuild --root "$STAGING/root" \
    --component-plist "$STAGING/components.plist" \
    --install-location / \
    --identifier local.appstoreplusplus.installer \
    --version "$VERSION" \
    --ownership recommended \
    "$OUTPUT"
echo "Installer: $OUTPUT"
