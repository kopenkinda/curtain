import Foundation
import SystemConfiguration
import Darwin
import IOKit.pwr_mgt

@main
struct HelperMain {
    static func main() throws {
        guard geteuid() == 0 else { exit(1) }
        let helper = PowerHelper()
        try helper.start()
        dispatchMain()
    }
}

// XPC callbacks, the watchdog, and signal handlers all serialize power changes
// through this queue. The exported methods accept no commands or file paths.
final class PowerHelper: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dk.curtain.power")
    private let listener = NSXPCListener(machServiceName: PowerIdentity.service)
    private var timer: DispatchSourceTimer?
    private var termination: DispatchSourceSignal?
    private var leases: [UUID: (uid: uid_t, deadline: TimeInterval, batteryLimit: Int)] = [:]
    private let journal = "/var/db/com.dk.curtain/owned"
    private var ownsSetting = false
    private var holding = false
    private var settingCheckedAt = -Double.infinity
    private var pendingBatterySleep = false
    private var lastFailure: String?
    private var battery: BatteryStatus?
    private var batteryReadAt = -Double.infinity

    func start() throws {
        let folder = (journal as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(folder, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == 0, directoryInfo.st_mode & 0o022 == 0 else {
            throw failure("The power recovery directory must be owned by root and not writable by other users.")
        }
        ownsSetting = FileManager.default.fileExists(atPath: journal)
        // Recover before accepting any client after a crash or system restart.
        queue.sync { _ = apply(active: false) }
        listener.setConnectionCodeSigningRequirement(try PowerIdentity.requirement(identifier: "com.dk.curtain"))
        listener.delegate = self
        listener.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [self] in _ = reconcile() }
        timer.resume()
        self.timer = timer
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termination.setEventHandler { [self] in
            // Keep the journal if powerd fails, so the next launch can retry.
            _ = apply(active: false)
            exit(0)
        }
        termination.resume()
        self.termination = termination
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        let id = UUID()
        connection.exportedInterface = NSXPCInterface(with: CurtainPowerProtocol.self)
        connection.exportedObject = PowerClient(helper: self, id: id, uid: connection.effectiveUserIdentifier)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            queue.async { [self] in leases[id] = nil; _ = reconcile() }
        }
        connection.resume()
        return true
    }

    func heartbeat(id: UUID, uid: uid_t, active: Bool, batteryLimit: Int, reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [self] in
            let console = consoleUser()
            guard console == uid else {
                leases[id] = nil
                _ = reconcile()
                reply(false, "Curtain is waiting for your login session.")
                return
            }
            refreshBattery()
            let limit = batteryLimit == 0 ? 0 : min(100, max(10, batteryLimit))
            guard limit == 0 || battery != nil else {
                leases[id] = nil
                _ = reconcile()
                reply(false, "Cannot read the battery level. Curtain has released sleep prevention.")
                return
            }
            // Let reconcile see an existing active lease crossing its cutoff,
            // before an incoming idle heartbeat can remove it.
            _ = reconcile()
            let lowBattery = battery?.reached(limit) == true
            if active && (!lowBattery || leases[id] != nil) { leases[id] = (uid, ProcessInfo.processInfo.systemUptime + 3, limit) }
            else { leases[id] = nil }
            let success = reconcile()
            reply(success, success ? (lowBattery ? "battery" : (active ? "active" : "ready")) : (lastFailure ?? "Could not change the sleep setting."))
        }
    }

    private func consoleUser() -> uid_t? {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil, uid != 0 else { return nil }
        return uid
    }

    private func reconcile() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let uid = consoleUser()
        refreshBattery()
        leases = leases.filter { $0.value.deadline > now && $0.value.uid == uid }
        let cutoffReached = leases.values.contains { battery?.reached($0.batteryLimit) == true }
        leases = leases.filter { $0.value.batteryLimit == 0 || (battery != nil && battery?.reached($0.value.batteryLimit) == false) }
        pendingBatterySleep = pendingBatterySleep || cutoffReached
        let success = apply(active: !leases.isEmpty)
        if pendingBatterySleep && leases.isEmpty && success {
            let port = IOPMFindPowerManagement(0)
            if port != 0 {
                let result = IOPMSleepSystem(port)
                IOServiceClose(port)
                if result != kIOReturnSuccess { lastFailure = "macOS declined the battery cutoff sleep request."; return false }
                pendingBatterySleep = false
            } else { lastFailure = "Could not request sleep at the battery cutoff."; return false }
        }
        return success
    }

    private func refreshBattery() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - batteryReadAt >= 1 {
            battery = BatteryStatus.read()
            batteryReadAt = now
        }
    }

    private func apply(active: Bool) -> Bool {
        do {
            let now = ProcessInfo.processInfo.systemUptime
            if active && holding && now - settingCheckedAt < 0.5 { return true }
            if active {
                let settings = try pmset(["-g"])
                guard let line = settings.split(separator: "\n").first(where: { $0.contains("SleepDisabled") }),
                      let original = line.split(whereSeparator: { $0.isWhitespace }).last,
                      original == "0" || original == "1" else { throw failure("Cannot read the current sleep setting.") }
                // Preserve a setting already owned by another application.
                if original == "1" {
                    holding = true
                    settingCheckedAt = now
                    lastFailure = nil
                    return true
                }
                holding = false
                if !ownsSetting {
                    // Write ownership durably before changing the persistent setting.
                    let file = open(journal, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
                    guard file >= 0 else { throw failure("Cannot record the sleep setting for recovery.") }
                    let written = "owned\n".withCString { write(file, $0, 6) }
                    let synced = fsync(file)
                    close(file)
                    guard written == 6, synced == 0 else { throw failure("Cannot save the sleep recovery record.") }
                    ownsSetting = true
                }
            }
            if active {
                _ = try pmset(["-a", "disablesleep", "1"])
                holding = true
                settingCheckedAt = now
            } else if ownsSetting {
                _ = try pmset(["-a", "disablesleep", "0"])
                try FileManager.default.removeItem(atPath: journal)
                ownsSetting = false
            }
            if !active { holding = false }
            lastFailure = nil
            return true
        } catch {
            holding = false
            lastFailure = error.localizedDescription
            return false
        }
    }

    private func pmset(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // A hung powerd must not block the watchdog indefinitely.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw failure("The macOS power service did not respond.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("macOS could not change the sleep setting.") }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func failure(_ description: String) -> NSError {
        NSError(domain: "CurtainPower", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

private final class PowerClient: NSObject, CurtainPowerProtocol, @unchecked Sendable {
    private let helper: PowerHelper
    private let id: UUID
    private let uid: uid_t
    init(helper: PowerHelper, id: UUID, uid: uid_t) { self.helper = helper; self.id = id; self.uid = uid }
    func heartbeat(_ active: Bool, batteryLimit: Int, withReply reply: @escaping (Bool, String) -> Void) {
        // Foundation's Objective-C callback predates Sendable annotations.
        let response = Response(reply)
        helper.heartbeat(id: id, uid: uid, active: active, batteryLimit: batteryLimit) { response.reply($0, $1) }
    }
    private final class Response: @unchecked Sendable {
        let reply: (Bool, String) -> Void
        init(_ reply: @escaping (Bool, String) -> Void) { self.reply = reply }
    }
}
