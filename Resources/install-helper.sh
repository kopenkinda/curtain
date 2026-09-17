#!/bin/bash
set -euo pipefail
set -x
# Called once through the macOS administrator prompt. Arguments are the signed
# bundle and its certificate-pinned helper requirement, never arbitrary commands.
[ "$(id -u)" = 0 ] || exit 1
bundle="$1"
requirement="$2"
helper_dir=/Library/PrivilegedHelperTools
plist_dir=/Library/LaunchDaemons
for directory in "$helper_dir" "$plist_dir"; do
    [ ! -L "$directory" ] || { echo 'Refusing a symbolic-link installation directory.' >&2; exit 1; }
    /usr/bin/install -d -o root -g wheel -m 755 "$directory"
done
staging="$(mktemp -d "$helper_dir/.Curtain.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/install -o root -g wheel -m 755 "$bundle/Contents/MacOS/CurtainPower" "$staging/CurtainPower"
/usr/bin/codesign --verify --strict -R "=$requirement" "$staging/CurtainPower"
# The daemon definition is fixed here; no caller-supplied launchd commands.
cat > "$staging/helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.dk.curtain.power</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/com.dk.curtain.power</string></array>
<key>MachServices</key><dict><key>com.dk.curtain.power</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>AssociatedBundleIdentifiers</key><array><string>com.dk.curtain</string></array>
</dict></plist>
PLIST
/usr/sbin/chown root:wheel "$staging/helper.plist"
/bin/chmod 644 "$staging/helper.plist"
/bin/launchctl bootout system/com.dk.curtain.power 2>/dev/null || true
/bin/mv -f "$staging/CurtainPower" "$helper_dir/com.dk.curtain.power"
/bin/mv -f "$staging/helper.plist" "$plist_dir/com.dk.curtain.power.plist"
/bin/launchctl enable system/com.dk.curtain.power
/bin/launchctl bootstrap system "$plist_dir/com.dk.curtain.power.plist"

printf "CURTAIN_HELPER_INSTALLED\n"
