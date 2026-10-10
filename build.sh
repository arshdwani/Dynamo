#!/bin/bash
# Builds build/dynamo (daemon + CLI) and build/Dynamo.app.
# ./build.sh test   also runs the policy tests.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

SWIFTC=(swiftc -O -target arm64-apple-macos13 -import-objc-header Sources/smc.h)
SHARED=(Sources/smc.c Sources/Shared/*.swift)

"${SWIFTC[@]}" "${SHARED[@]}" Sources/Daemon/*.swift -framework IOKit -o build/dynamo

# Build the app beside the old one and swap it in at the end, so a concurrent
# install.sh never copies a half-built bundle.
FINAL=build/Dynamo.app
APP=build/.Dynamo.app.partial
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"${SWIFTC[@]}" -parse-as-library "${SHARED[@]}" Sources/App/*.swift -framework IOKit \
    -o "$APP/Contents/MacOS/Dynamo"
cp Resources/Info.plist "$APP/Contents/"
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' Sources/Shared/Version.swift)
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - build/dynamo
codesign --force --sign - "$APP"
rm -rf "$FINAL"
mv "$APP" "$FINAL"

if [[ "${1:-}" == snapshot ]]; then
    APP_SOURCES=$(ls Sources/App/*.swift | grep -v '/App.swift$')
    "${SWIFTC[@]}" "${SHARED[@]}" $APP_SOURCES Tools/Snapshot/main.swift -framework IOKit -o build/snapshot
    ./build/snapshot build/snapshots
fi

if [[ "${1:-}" == test ]]; then
    "${SWIFTC[@]}" "${SHARED[@]}" Tests/Policy/main.swift -framework IOKit -o build/tests
    ./build/tests
fi
echo "Built build/dynamo and build/Dynamo.app"
