import AppKit

@MainActor
final class SettingsWindow: NSWindowController {
    private let slider: NSSlider
    private let activationLabel = NSTextField(labelWithString: "")
    private let liveLabel = NSTextField(labelWithString: "Reading lid angle…")
    private let reopeningLabel = NSTextField(wrappingLabelWithString: "")
    private let useCurrent = NSButton(title: "Use Current Angle", target: nil, action: nil)
    private var currentAngle: Double?
    private let onChange: (Double) -> Void
    private let onBatteryChange: () -> Void
    private let batteryToggle = NSButton(checkboxWithTitle: "Sleep at low battery", target: nil, action: nil)
    private let batterySlider = NSSlider(value: 20, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let batteryLabel = NSTextField(labelWithString: "")

    init(activationAngle: Double, onBatteryChange: @escaping () -> Void, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        self.onBatteryChange = onBatteryChange
        slider = NSSlider(value: activationAngle, minValue: 5, maxValue: 160, target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Curtain Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let title = NSTextField(labelWithString: "Activation angle")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        activationLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        activationLabel.setContentHuggingPriority(.required, for: .horizontal)
        let heading = NSStackView(views: [title, NSView(), activationLabel])
        heading.orientation = .horizontal
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        liveLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        useCurrent.target = self
        useCurrent.action = #selector(captureAngle)
        useCurrent.bezelStyle = .rounded
        let liveRow = NSStackView(views: [liveLabel, NSView(), useCurrent])
        liveRow.orientation = .horizontal
        let explanation = NSTextField(wrappingLabelWithString:
            "Hold Option and lower the lid to this angle to activate. A larger angle activates earlier. 0° is fully shut.")
        explanation.textColor = .secondaryLabelColor
        reopeningLabel.textColor = .secondaryLabelColor
        let separator = NSBox()
        separator.boxType = .separator
        batteryToggle.state = UserDefaults.standard.bool(forKey: "batteryCutoffEnabled") ? .on : .off
        batteryToggle.target = self
        batteryToggle.action = #selector(batteryChanged)
        batterySlider.doubleValue = Double(min(100, max(10, UserDefaults.standard.integer(forKey: "batteryCutoff"))))
        batterySlider.target = self
        batterySlider.action = #selector(batteryChanged)
        batterySlider.isContinuous = true
        batteryLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        batteryLabel.setContentHuggingPriority(.required, for: .horizontal)
        let batteryHeading = NSStackView(views: [batteryToggle, NSView(), batteryLabel])
        batteryHeading.orientation = .horizontal
        let batteryNote = NSTextField(wrappingLabelWithString: "While running on battery, Curtain stops and puts the Mac to sleep at this percentage. Turn this off to keep running without a battery cutoff.")
        batteryNote.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, slider, explanation, liveRow, reopeningLabel,
                                        separator, batteryHeading, batterySlider, batteryNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            liveRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reopeningLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            batteryHeading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            batterySlider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            batteryNote.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateLabels()
        updateBatteryLabels()
        update(currentAngle: nil)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(currentAngle: Double?) {
        self.currentAngle = currentAngle
        liveLabel.stringValue = currentAngle.map { "Current lid angle: \(Int($0))°" } ?? "Lid sensor unavailable"
        useCurrent.isEnabled = currentAngle.map { (5...160).contains($0) } ?? false
    }

    @objc private func sliderChanged() {
        slider.doubleValue = slider.doubleValue.rounded()
        updateLabels()
        onChange(slider.doubleValue)
    }

    @objc private func captureAngle() {
        guard let currentAngle, (5...160).contains(currentAngle) else { return }
        slider.doubleValue = currentAngle.rounded()
        sliderChanged()
    }

    @objc private func batteryChanged() {
        batterySlider.doubleValue = batterySlider.doubleValue.rounded()
        UserDefaults.standard.set(batteryToggle.state == .on, forKey: "batteryCutoffEnabled")
        UserDefaults.standard.set(Int(batterySlider.doubleValue), forKey: "batteryCutoff")
        updateBatteryLabels()
        onBatteryChange()
    }

    private func updateBatteryLabels() {
        batterySlider.isEnabled = batteryToggle.state == .on
        batteryLabel.stringValue = batteryToggle.state == .on ? "\(Int(batterySlider.doubleValue))%" : "Off"
    }

    private func updateLabels() {
        activationLabel.stringValue = "\(Int(slider.doubleValue))°"
        reopeningLabel.stringValue = "Open past \(Int(slider.doubleValue) + 5)° to dismiss or start a new gesture. Changes save automatically."
    }
}
