import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class SettingsWindow: NSWindowController {
    private let readings = LidReadings()
    private let tabs = NSTabViewController()

    init(onBatteryChange: @escaping () -> Void, onAngleChange: @escaping (Double) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Curtain Settings"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)

        tabs.tabStyle = .toolbar
        for (title, symbol, view, height) in [
            ("Settings", "gearshape", AnyView(SettingsPane(readings: readings,
                onBatteryChange: onBatteryChange, onAngleChange: onAngleChange)), 440.0),
            ("How to Use Curtain", "questionmark.circle", AnyView(InstructionsPane()), 420.0)
        ] {
            let host = NSHostingController(rootView: view)
            host.preferredContentSize = NSSize(width: 520, height: height)
            let tab = NSTabViewItem(viewController: host)
            tab.label = title
            tab.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(tab)
        }
        window.contentViewController = tabs
        window.toolbarStyle = .preference
        window.toolbar?.displayMode = .iconAndLabel
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("SettingsWindow is created in code.") }

    func update(currentAngle: Double?) {
        if readings.angle != currentAngle { readings.angle = currentAngle }
    }

    func show(tab: Int = 0) {
        tabs.selectedTabViewItemIndex = tab
        showWindow(nil)
        NSApp.activate()
    }
}

@MainActor
private final class LidReadings: ObservableObject {
    @Published var angle: Double?
}

private struct SettingsPane: View {
    @ObservedObject var readings: LidReadings
    var onBatteryChange: () -> Void
    var onAngleChange: (Double) -> Void
    @AppStorage("mute") private var muted = false
    @AppStorage("activationAngle") private var activationAngle = 27.0
    @AppStorage("batteryCutoffEnabled") private var batteryCutoffEnabled = true
    @AppStorage("batteryCutoff") private var batteryCutoff = 20
    @State private var openAtLogin = false
    @State private var loginNeedsApproval = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                Toggle("Play activation sound", isOn: Binding(get: { !muted }, set: { muted = !$0 }))
            } header: {
                Text("General")
            } footer: {
                if loginNeedsApproval {
                    Button("Approve Open at Login in System Settings…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.link)
                }
            }

            Section {
                HStack {
                    Text("Activation angle")
                    Spacer()
                    Slider(value: Binding(get: { activationAngle }, set: { activationAngle = $0.rounded() }), in: 5...160)
                        .labelsHidden().frame(width: 150)
                        .accessibilityLabel("Activation angle")
                    Text("\(Int(activationAngle))°")
                        .monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                HStack {
                    Text(readings.angle.map { "Current lid angle: \(Int($0))°" } ?? "Lid sensor unavailable")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Use Current Angle") {
                        if let angle = readings.angle { activationAngle = angle.rounded() }
                    }
                    .controlSize(.small)
                    .disabled(readings.angle.map { !(5...160).contains($0) } ?? true)
                }
            } header: {
                Text("Lid")
            } footer: {
                Text("Larger angles activate sooner. Open past \(Int(activationAngle) + 5)° to dismiss.")
            }

            Section {
                Toggle("Sleep at low battery", isOn: $batteryCutoffEnabled)
                HStack {
                    Text("Battery cutoff")
                    Spacer()
                    Slider(value: Binding(get: { Double(batteryCutoff) }, set: { batteryCutoff = Int($0.rounded()) }),
                           in: 10...100)
                        .labelsHidden().frame(width: 150)
                        .accessibilityLabel("Battery cutoff")
                    Text("\(batteryCutoff)%")
                        .monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                .disabled(!batteryCutoffEnabled)
            } header: {
                Text("Battery")
            } footer: {
                Text("Stops Curtain and puts your Mac to sleep while running on battery.")
            }
        }
        .toggleStyle(.switch)
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
        .onAppear(perform: refreshLoginState)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginState()
        }
        .onChange(of: activationAngle) { _, value in onAngleChange(value) }
        .onChange(of: batteryCutoffEnabled) { _, _ in onBatteryChange() }
        .onChange(of: batteryCutoff) { _, _ in onBatteryChange() }
        .alert("Couldn't change Open at Login", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage) }
    }

    private func refreshLoginState() {
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        refreshLoginState()
    }
}

private struct InstructionsPane: View {
    @AppStorage("activationAngle") private var activationAngle = 27.0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hold Option. Close the lid.")
                    .font(.title2.weight(.semibold))
                Text("Enable Curtain from the menu bar. The first setup asks for administrator approval just once.")
                    .foregroundStyle(.secondary)
            }

            step("1", title: "Hold ⌥ Option and lower the lid",
                 detail: "The curtain follows the lid and activates at \(Int(activationAngle))°.")
            step("2", title: "Close your Mac completely",
                 detail: "Release Option after activation. The sound plays when the lid is fully shut, and your Mac keeps working.")
            step("3", title: "Open the lid to return",
                 detail: "Open past \(Int(activationAngle) + 5)° to lift the curtain and restore normal sleep.")

            Divider()
            Text("Escape dismisses the curtain. Releasing Option before activation cancels. Turn on Open at Login in Settings to start automatically.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 520, height: 420, alignment: .topLeading)
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
