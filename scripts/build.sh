#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p .build
staging="$(mktemp -d "$PWD/.build/.staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Curtain.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
options=(-swift-version 6 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx27.0" -g)
if [ "${CONFIGURATION:-Debug}" = Release ]; then options+=(-O); else options+=(-Onone); fi
xcrun swiftc "${options[@]}" -parse-as-library -module-name Curtain Sources/Shared/*.swift Sources/Curtain/*.swift -o "$app/Contents/MacOS/Curtain"
xcrun swiftc "${options[@]}" -parse-as-library -module-name CurtainPower Sources/Shared/*.swift Sources/PowerHelper/*.swift -o "$app/Contents/MacOS/CurtainPower"
cp Resources/install-helper.sh "$app/Contents/Resources/"
cp Resources/Activation.wav "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/Info.plist"
xcrun actool Artwork/Curtain.icon \
    --compile "$app/Contents/Resources" \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist "$staging/icon-info.plist" \
    --app-icon Curtain --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --minimum-deployment-target 27.0 --platform macosx
xcrun swift scripts/make-icon.swift Artwork/Curtain.icon/Assets/Curtain.svg "$app/Contents/Resources/CurtainMenu.png"
python3 scripts/sign.py "$app"
destination="$PWD/.build/Curtain.app"
if [ -d "$destination" ]; then mv "$destination" "$staging/previous.app"; fi
if ! mv "$app" "$destination"; then
    if [ -d "$staging/previous.app" ]; then mv "$staging/previous.app" "$destination"; fi
    exit 1
fi
printf 'Built %s\n' "$destination"
