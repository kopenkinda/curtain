import AppKit
import IOKit.pwr_mgt
import ServiceManagement

@main
struct CurtainMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sensor = LidSensor()
    private let overlay = CurtainOverlay()
    private let power = PowerSession()
    private var statusItem: NSStatusItem!
    private lazy var menuIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "CurtainMenu", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Curtain"
        return image
    }()
    private var timer: Timer?
    private var active = false
    private var closingSoundPlayed = false
    private var armed = false
    private var enabled = false
    private var paused = false
    private var angle: Double?
    private var fraction = 0.0
    private var previewUntil: Date?
    private var lastSensorReading = Date()
    private var lastSensorPoll = Date.distantPast
    private lazy var activationSound = Bundle.main.url(forResource: "Activation", withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: false) }
    private var assertion: IOPMAssertionID = 0
    private var escapeWasDown = false
    private var openingAngle = 90.0
    private var notice: String?
    private var settings: SettingsWindow?
    private var activationAngle: Double {
        min(160, max(5, UserDefaults.standard.double(forKey: "activationAngle")))
    }
    private var reopeningAngle: Double { activationAngle + 5 }
    private var soundEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "mute") }
        set { UserDefaults.standard.set(!newValue, forKey: "mute") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.dk.curtain").count == 1 else {
            NSApp.terminate(nil)
            return
        }
        UserDefaults.standard.register(defaults: ["activationAngle": 27.0, "enabled": true, "batteryCutoffEnabled": true, "batteryCutoff": 20])
        overlay.onDismiss = { [weak self] in self?.dismiss() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = menuIcon
        statusItem.button?.toolTip = "Curtain: hold Option and lower the lid"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspend),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspend),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        if UserDefaults.standard.bool(forKey: "enabled") {
            // Offer installation once. Later launches never produce an
            // unexpected password prompt if setup was cancelled or removed.
            let offerSetup = !UserDefaults.standard.bool(forKey: "helperSetupOffered")
            UserDefaults.standard.set(true, forKey: "helperSetupOffered")
            do {
                try power.start(allowInstallation: offerSetup)
                enabled = true
            } catch { notice = error.localizedDescription }
        }
        if !UserDefaults.standard.bool(forKey: "introduced") {
            UserDefaults.standard.set(true, forKey: "introduced")
            showInstructions()
        }
    }

    private func tick() {
        let now = Date()
        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: 53)
        defer { escapeWasDown = escapeDown }
        if escapeDown && !escapeWasDown { dismiss() }
        if let previewUntil {
            if now >= previewUntil { self.previewUntil = nil; overlay.hide(); fraction = 0 }
            return
        }
        let option = NSEvent.modifierFlags.contains(.option)
        if enabled || settings?.window?.isVisible == true || now.timeIntervalSince(lastSensorPoll) >= 1 {
            lastSensorPoll = now
            if let reading = sensor.read() {
                angle = reading
                lastSensorReading = now
            } else {
                angle = nil
                if now.timeIntervalSince(lastSensorReading) > 3 {
                    dismiss()
                    notice = "Lid sensor unavailable"
                }
            }
        }
        settings?.update(currentAngle: angle)
        guard enabled else { return }
        let state = power.state
        if state == "error" || (state == nil && !power.authorizing) {
            dismiss()
            enabled = false
            notice = power.errorMessage ?? "Could not reach the sleep helper. Choose Enable Curtain to reconnect."
            power.stop()
            return
        }
        if state == "battery" {
            if active || armed || fraction > 0 { dismiss() }
            notice = "Paused: battery is at or below \(UserDefaults.standard.integer(forKey: "batteryCutoff"))%."
            power.heartbeat(active: false)
            return
        }
        if notice?.hasPrefix("Paused: battery") == true { notice = nil }
        guard state == "ready" || state == "active" else {
            power.heartbeat(active: false)
            return
        }
        if active {
            if let angle, angle >= reopeningAngle {
                dismiss()
            } else if !closingSoundPlayed && sensor.isClosed == true {
                closingSoundPlayed = true
                if soundEnabled { activationSound?.play() }
            }
            power.heartbeat(active: active)
            return
        }
        guard let angle else {
            power.heartbeat(active: active)
            return
        }
        if paused {
            if !option && angle >= reopeningAngle { paused = false }
            power.heartbeat(active: false)
            return
        }
        if !option {
            if armed || fraction > 0 { dismiss() }
            power.heartbeat(active: false)
            return
        }
        if !armed && angle >= reopeningAngle {
            armed = true
            openingAngle = angle
            notice = nil
        }
        guard armed else { power.heartbeat(active: false); return }
        openingAngle = max(openingAngle, angle)
        // Enable lid-close protection before the hinge reaches the Hall sensor.
        power.heartbeat(active: true)
        let start = min(activationAngle + 40, openingAngle - 1)
        let progress = min(1, max(0, (start - angle) / (start - activationAngle)))
        if progress > 0 || fraction > 0 {
            fraction = progress
            overlay.cover(progress)
        }
        if angle <= activationAngle && power.state == "active" {
            active = true
            armed = false
            fraction = 1
            overlay.cover(1, animated: true)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Curtain is closed" as CFString, &assertion)
            if result != kIOReturnSuccess { assertion = 0 }
            statusItem.button?.toolTip = "Curtain active: Mac stays awake"
        }
    }

    private func dismiss() {
        active = false
        closingSoundPlayed = false
        armed = false
        fraction = 0
        previewUntil = nil
        paused = true
        overlay.hide()
        power.heartbeat(active: false, force: true)
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        statusItem?.button?.toolTip = "Curtain: hold Option and lower the lid"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let title: String
        if active { title = "Curtain active · Mac stays awake" }
        else if power.authorizing { title = power.installed ? "Connecting to sleep helper…" : "Waiting for one-time setup…" }
        else if let notice { title = notice }
        else if enabled { title = "Hold ⌥ Option and lower the lid" }
        else { title = "Curtain is disabled" }
        let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let angle {
            let item = NSMenuItem(title: "Lid angle: \(Int(angle))°", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, enabled ? "Disable Curtain" : "Enable Curtain…", #selector(toggleEnabled))
        add(menu, "Preview Curtain", #selector(preview))
        add(menu, "Play Activation Sound", #selector(toggleSound), checked: soundEnabled)
        add(menu, "Open at Login", #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(showSettings), key: ",")
        add(menu, "How to Use Curtain", #selector(showInstructions))
        add(menu, "Quit Curtain", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", checked: Bool? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let checked { item.state = checked ? .on : .off }
        menu.addItem(item)
    }

    @objc private func toggleEnabled() {
        if enabled {
            dismiss()
            power.stop()
            enabled = false
            notice = nil
            UserDefaults.standard.set(false, forKey: "enabled")
        } else {
            do {
                try power.start()
                enabled = true
                UserDefaults.standard.set(true, forKey: "enabled")
                paused = false
                notice = nil
            } catch { showError(error.localizedDescription) }
        }
    }

    @objc private func preview() {
        dismiss()
        // Let the menu close before covering it. Preview always dismisses itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            previewUntil = Date().addingTimeInterval(2)
            fraction = 1
            overlay.cover(1, animated: true)
        }
    }

    @objc private func showSettings() {
        if settings == nil {
            settings = SettingsWindow(activationAngle: activationAngle, onBatteryChange: { [weak self] in
                guard let self else { return }
                power.heartbeat(active: active || armed, force: true)
            }) { [weak self] value in
                self?.dismiss()
                UserDefaults.standard.set(value, forKey: "activationAngle")
            }
        }
        settings?.update(currentAngle: angle)
        settings?.showWindow(nil)
        NSApp.activate()
    }

    @objc private func toggleSound() { soundEnabled.toggle() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError(error.localizedDescription) }
    }
    @objc private func screensChanged() {
        if fraction > 0 { overlay.rebuild(fraction: fraction) }
    }
    @objc private func suspend() { dismiss(); sensor.disconnect() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showInstructions() {
        let alert = NSAlert()
        alert.messageText = "Hold Option. Lower the lid."
        alert.informativeText = "Enable Curtain and approve the one-time sleep helper installation. Curtain remembers whether it is enabled, including after updates and restarts. Turn on Open at Login to start automatically. Hold ⌥ Option while lowering the lid. The black curtain follows the lid and activates at \(Int(activationAngle))°. You can then release Option and close the Mac completely. The sound plays once the lid is fully shut.\n\nOpen past \(Int(reopeningAngle))° to lift the curtain and restore normal sleep. Escape also dismisses it. Releasing Option before activation cancels.\n\nChange the activation angle in Settings, or choose Use Current Angle to match the lid position. Preview shows the animation for two seconds. Curtain covers your screens; applications continue running underneath."
        alert.addButton(withTitle: "Got It")
        NSApp.activate()
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Curtain couldn't complete that action"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        dismiss()
        overlay.hide(animated: false)
        power.stop()
        sensor.disconnect()
    }
}
