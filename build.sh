#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP=build/LangSwitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$APP/Contents/MacOS/LangSwitch" \
    Sources/main.swift

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x LangSwitch || true
    rm -rf /Applications/LangSwitch.app
    cp -R "$APP" /Applications/
    open /Applications/LangSwitch.app
    echo "Installed to /Applications"
fi
