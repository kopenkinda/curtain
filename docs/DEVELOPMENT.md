# Development notes

## Behavior and limits

Choose **Sliding curtain** (the default) or **Perspective** in Settings. Perspective holds a desktop snapshot in a fixed virtual plane and orbits a perspective camera around the hinge using the lid’s angular travel. The projection uses the center of the screen as its optical center, with no additional shrinking or translation. Blur increases as the lid closes, and the display becomes fully black when shut. It requires Screen Recording permission; without permission, Curtain uses the sliding style. Snapshots stay in memory, are discarded when the lid shuts or the gesture ends, and are refreshed on reopening. They are never saved.

The black overlay covers every connected screen and sits above ordinary app windows, including full-screen apps. The sliding style does not capture the screen. Neither style stops background applications from rendering. A black LCD image does not switch off its backlight. macOS controls panel power when the lid is fully closed. The overlay is not a screen lock and does not cover macOS secure login screens.

The hinge reader uses the MacBook's HID sensor, usage page `0x20`, usage `0x8A`, report 1. This is undocumented hardware behavior and is not available on every Mac. See the [LidAngleSensor project](https://github.com/samhenrigold/LidAngleSensor) for sensor background. If the sensor stops responding for three seconds, Curtain cancels the session. It does not substitute an estimated angle.

Normal sleep assertions do not reliably prevent lid-close sleep. A small root-owned helper uses `/usr/bin/pmset -a disablesleep` to manage that setting. One administrator approval installs the helper at `/Library/PrivilegedHelperTools/com.dk.curtain.power` and its launchd definition at `/Library/LaunchDaemons/com.dk.curtain.power.plist`. The app and helper authenticate XPC connections against their identifiers and the same pinned local signing certificate. The helper accepts only an active/idle request and a battery cutoff, not shell commands or caller-supplied file paths.

The helper expires sleep-prevention requests after three seconds without a heartbeat and also releases them when the client disconnects or its login session is no longer active. It only restores settings it changed itself. A root-owned recovery record in `/var/db/com.dk.curtain` lets launchd restart the helper and restore sleep after a helper crash or reboot. While active, the helper checks the sleep setting every half-second and restores protection if another app clears it. If another app had already disabled sleep, Curtain preserves that setting until it needs to take over. These checks cannot eliminate the brief race with another app changing the same global setting.

Builds replace the app bundle. On connection, Curtain compares the installed helper with the bundled executable and refuses to use a different copy. Choose Enable Curtain to approve installation of the bundled helper when an update is needed. An identical helper is reused without a password prompt. Keep the signing identity intact so the helper recognizes rebuilt copies.

The helper checks battery level once per second while handling heartbeats. At the cutoff it releases its setting and uses `IOPMSleepSystem` to request sleep. Disabling the cutoff leaves macOS's own critical-battery behavior in control; it does not override hardware power limits.

## Remove the helper

Quit Curtain first, then run:

```sh
sudo launchctl bootout system/com.dk.curtain.power
sudo rm /Library/LaunchDaemons/com.dk.curtain.power.plist /Library/PrivilegedHelperTools/com.dk.curtain.power
```

The helper restores its sleep setting on termination. If sleep remains disabled after a failed cleanup, use `sudo pmset -a disablesleep 0`. Reopen Curtain and choose Enable Curtain to reinstall the helper when needed.

No automated tests have been added or run during the initial build.

Regenerate the README banner with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/render-readme.swift`. It uses the app’s Icon Composer asset and native macOS typography.
