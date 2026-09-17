import SwiftUI

struct ActivationKey: Codable, Equatable {
    // A nil code preserves the original behavior: either Option key works.
    var code: UInt16?
    var label: String
    static let option = ActivationKey(code: nil, label: "⌥ Option / Alt")

    var isDown: Bool {
        if let code { return CGEventSource.keyState(.combinedSessionState, key: code) }
        return NSEvent.modifierFlags.contains(.option)
    }
}

@MainActor
final class ActivationBinding: ObservableObject {
    @Published var key: ActivationKey {
        didSet {
            if let data = try? JSONEncoder().encode(key) {
                UserDefaults.standard.set(data, forKey: "activationKey")
            }
        }
    }
    @Published var recording = false
    var onChange: () -> Void = {}

    init() {
        if let data = UserDefaults.standard.data(forKey: "activationKey"),
           let saved = try? JSONDecoder().decode(ActivationKey.self, from: data),
           saved.code != 53, saved.code != 57, !saved.label.isEmpty {
            key = saved
        } else {
            key = .option
        }
    }
}

struct ActivationKeyRecorder: View {
    @ObservedObject var binding: ActivationBinding
    @State private var monitor: Any?
    @State private var candidate: ActivationKey?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Activation key") {
                if binding.recording {
                    Text(candidate.map { "Release \($0.label)…" } ?? "Press a key…")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { finish() }
                } else {
                    Button(binding.key.label, action: begin)
                        .help("Record an activation key")
                        .accessibilityLabel("Record activation key: \(binding.key.label)")
                    if binding.key != .option {
                        Button { finish(.option) } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .help("Reset to Option / Alt").accessibilityLabel("Reset activation key to Option / Alt")
                    }
                }
            }
            Text(message ?? "Hold this key while lowering the lid. It keeps its normal behavior in other apps.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { if binding.recording { finish() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if binding.recording { finish() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if binding.recording { finish() }
        }
    }

    private func begin() {
        binding.recording = true
        binding.onChange()
        candidate = nil
        message = "Press one key. Escape cancels."
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let consumed = MainActor.assumeIsolated { handle(event) == nil }
            return consumed ? nil : event
        }
        if monitor == nil {
            finish()
            message = "Could not record a key. Try again."
        }
    }

    private func finish(_ key: ActivationKey? = nil) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        candidate = nil
        message = nil
        if let key { binding.key = key }
        binding.recording = false
        binding.onChange()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard binding.recording else { return event }
        let code = event.keyCode
        if code == 53, event.type == .keyDown { finish(); return nil }
        if code == 57 {
            candidate = nil
            message = "Caps Lock can't be used for hold-to-activate."
            return nil
        }
        let down = event.type == .flagsChanged
            ? CGEventSource.keyState(.combinedSessionState, key: code)
            : event.type == .keyDown
        if !down {
            // Commit on release so the recorded press cannot start activation.
            if let candidate, candidate.code == code { finish(candidate) }
            return nil
        }
        if event.type == .keyDown, event.isARepeat { return nil }
        var modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch code {
        case 54, 55: modifiers.remove(.command)
        case 59, 62: modifiers.remove(.control)
        case 58, 61: modifiers.remove(.option)
        case 56, 60: modifiers.remove(.shift)
        default: break
        }
        guard modifiers.isEmpty, candidate == nil || candidate?.code == code else {
            candidate = nil
            message = "Choose a single key, without a key combination."
            return nil
        }
        candidate = ActivationKey(code: code, label: Self.label(for: event))
        message = nil
        return nil
    }

    private static func label(for event: NSEvent) -> String {
        let names: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 63: "Globe / Fn",
            54: "Right Command", 55: "Left Command", 56: "Left Shift", 60: "Right Shift",
            58: "Left Option", 61: "Right Option", 59: "Left Control", 62: "Right Control",
            76: "Keypad Enter", 114: "Help", 115: "Home", 116: "Page Up",
            117: "Forward Delete", 119: "End", 121: "Page Down",
            123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow"
        ]
        if let name = names[event.keyCode] { return name }
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           (0xF704...0xF726).contains(scalar.value) {
            return "F\(scalar.value - 0xF704 + 1)"
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            let label = characters.uppercased()
            return event.modifierFlags.contains(.numericPad) ? "Keypad \(label)" : label
        }
        return "Key \(event.keyCode)"
    }
}
