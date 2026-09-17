#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
# Stage and verify the whole bundle before replacing the installed app.
# Use the same development install convention as Menu Dot and Blah.
# Keep the same path across every update.
app="/Applications/Curtain.app"
if [ -e "$app" ]; then
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"
    [ "$installed_id" = com.dk.curtain ] || { echo 'A different app occupies the install path.' >&2; exit 1; }
fi
staging="$(mktemp -d /Applications/.Curtain.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
ditto .build/Curtain.app "$staging/Curtain.app"
codesign --verify --deep --strict "$staging/Curtain.app"

# Quit normally to release the sleep assertion.
swift -e '
import AppKit
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dk.curtain")
for app in apps { app.terminate() }
let deadline = Date().addingTimeInterval(5)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
if apps.contains(where: { !$0.isTerminated }) {
    fputs("Quit Curtain before installing the update.\n", stderr)
    exit(1)
}
'
if [ -d "$app" ]; then mv "$app" "$staging/previous.app"; fi
if ! mv "$staging/Curtain.app" "$app"; then
    if [ -d "$staging/previous.app" ]; then mv "$staging/previous.app" "$app"; fi
    exit 1
fi
open "$app"
