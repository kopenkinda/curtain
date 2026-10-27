import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "com.dk.curtain", category: "power")
// Failed or missing replies are tolerated this long before the session is
// treated as broken. powerd can stall for seconds while the lid closes.
private let failureTolerance: TimeInterval = 15

@MainActor
final class PowerSession {
    private var connection: NSXPCConnection?
    private var authorization: Process?
    private var wantsConnection = false
    private var connectingSince = Date.distantPast
    private var lastWrite = Date.distantPast
    private var lastCommand = false
    private var lastReply = Date.distantPast
    private var failingSince: Date?
    private var generation = 0
    private(set) var state: String?
    private(set) var errorMessage: String?
    var authorizing: Bool { authorization?.isRunning == true || (wantsConnection && state == nil && Date().timeIntervalSince(connectingSince) < 10) }
    var installed: Bool { FileManager.default.fileExists(atPath: PowerIdentity.helperPath) }

    var helperIsCurrent: Bool {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "CurtainPower") else { return false }
        return FileManager.default.contentsEqual(atPath: PowerIdentity.helperPath, andPath: bundled.path)
    }

    func start(allowInstallation: Bool = true) throws {
        stop()
        errorMessage = nil
        wantsConnection = true
        connectingSince = Date()
        if installed && helperIsCurrent {
            try connect()
        } else if allowInstallation {
            try install()
        } else {
            state = "error"
            errorMessage = "Choose Enable Curtain to install or update the sleep helper."
        }
    }

    private func install() throws {
        guard let script = Bundle.main.url(forResource: "install-helper", withExtension: "sh") else {
            throw NSError(domain: "Curtain", code: 1, userInfo: [NSLocalizedDescriptionKey: "The helper installer is missing."])
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let requirement = try PowerIdentity.requirement(identifier: PowerIdentity.service)
        let command = "/bin/bash " + quote(script.path) + " " + quote(Bundle.main.bundlePath) + " " + quote(requirement)
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges with prompt \"Curtain needs to install or update its sleep helper.\""]
        let errors = Pipe()
        process.standardOutput = errors
        process.standardError = errors
        let current = generation
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor [weak self] in
                guard let self, generation == current, wantsConnection else { return }
                authorization = nil
                if status == 0 && helperIsCurrent && details.contains("CURTAIN_HELPER_INSTALLED") {
                    connectingSince = Date()
                    do { try connect() } catch { fail(error.localizedDescription) }
                } else {
                    let message = details.isEmpty ? "The installer exited with status \(status) without installing the helper." : details
                    fail("Helper setup failed: \(message)")
                    let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Curtain-setup.log")
                    try? message.write(to: log, atomically: true, encoding: .utf8)
                    let alert = NSAlert()
                    alert.messageText = "Curtain couldn't install its sleep helper"
                    alert.informativeText = message
                    NSApp.activate()
                    alert.runModal()
                }
            }
        }
        try process.run()
        authorization = process
    }

    private func connect() throws {
        let connection = NSXPCConnection(machServiceName: PowerIdentity.service, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CurtainPowerProtocol.self)
        connection.setCodeSigningRequirement(try PowerIdentity.requirement(identifier: PowerIdentity.service))
        let current = generation
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == current else { return }
                self.connection = nil
                fail("The sleep helper disconnected. Choose Enable Curtain to reconnect.")
            }
        }
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == current else { return }
                state = nil
                lastReply = .distantPast
                connectingSince = Date()
            }
        }
        connection.resume()
        self.connection = connection
        heartbeat(active: false, force: true)
    }

    func heartbeat(active: Bool, force: Bool = false) {
        guard wantsConnection, let connection else { return }
        let now = Date()
        if lastReply != .distantPast && now.timeIntervalSince(lastReply) > failureTolerance {
            fail("The sleep helper stopped responding. Choose Enable Curtain to reconnect.")
            return
        }
        guard force || active != lastCommand || now.timeIntervalSince(lastWrite) >= 0.5 else { return }
        lastWrite = now
        lastCommand = active
        let current = generation
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, generation == current else { return }
                transientFailure("Could not reach the sleep helper. \(message)")
            }
        } as? CurtainPowerProtocol
        let cutoff = UserDefaults.standard.bool(forKey: "batteryCutoffEnabled")
            ? min(100, max(10, UserDefaults.standard.integer(forKey: "batteryCutoff"))) : 0
        proxy?.heartbeat(active, batteryLimit: cutoff) { @Sendable [weak self] success, message in
            Task { @MainActor [weak self] in
                guard let self, generation == current else { return }
                lastReply = Date()
                if success {
                    if failingSince != nil { log.notice("Sleep helper recovered") }
                    failingSince = nil
                    state = message
                    errorMessage = nil
                } else { transientFailure(message) }
            }
        }
    }

    private func fail(_ message: String) {
        log.error("Sleep helper failed: \(message, privacy: .public)")
        state = "error"
        errorMessage = message
    }

    // Keep the current state, so an active session keeps sending heartbeats,
    // unless failures persist.
    private func transientFailure(_ message: String) {
        let now = Date()
        if failingSince == nil {
            failingSince = now
            log.notice("Sleep helper reported a problem: \(message, privacy: .public)")
        }
        errorMessage = message
        if let failingSince, now.timeIntervalSince(failingSince) > failureTolerance { fail(message) }
    }

    func stop() {
        wantsConnection = false
        generation += 1
        // XPC invalidation releases this client's lease; the watchdog also
        // expires it within three seconds if the process disappears abruptly.
        connection?.invalidate()
        connection = nil
        authorization = nil
        state = nil
        lastWrite = .distantPast
        lastReply = .distantPast
        failingSince = nil
        lastCommand = false
    }
}
