import AppKit
import QuartzCore
import ScreenCaptureKit
import CoreImage

enum CurtainStyle: String, CaseIterable, Identifiable {
    case sliding, perspective
    var id: String { rawValue }
    var title: String { self == .sliding ? "Sliding curtain" : "Perspective" }
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "curtainStyle") ?? "") ?? .sliding
    }
}

@MainActor
final class CurtainOverlay {
    private var panels: [CurtainPanel] = []
    private var generation = 0
    private var captureTask: Task<Void, Never>?
    private var snapshots: [CGDirectDisplayID: CGImage] = [:]
    private var fraction = 0.0
    private var rotationDegrees = 0.0
    private var fullyClosed = false
    private(set) var style = CurtainStyle.sliding
    var onDismiss: (() -> Void)?
    var onCaptureFailure: ((String) -> Void)?

    func begin() {
        remove()
        fraction = 0
        rotationDegrees = 0
        fullyClosed = false
        style = CurtainStyle.current
        if style == .perspective {
            guard CGPreflightScreenCaptureAccess() else {
                style = .sliding
                onCaptureFailure?("Perspective needs Screen Recording access in Settings. Using the sliding curtain.")
                return
            }
            captureDesktop()
        }
    }

    func cover(_ fraction: Double, rotationDegrees: Double = 0, fullyClosed: Bool = false, animated: Bool = false) {
        self.fraction = min(1, max(0, fraction))
        self.rotationDegrees = rotationDegrees
        let reopening = self.fullyClosed && !fullyClosed
        self.fullyClosed = fullyClosed
        if style == .perspective {
            if fullyClosed {
                cancelCapture()
                snapshots.removeAll()
                panels.forEach { $0.setSnapshot(nil) }
            } else if reopening {
                captureDesktop()
            }
            // Leave the real desktop visible until the first snapshot arrives.
            // During reopening, keep the closed black panel until a fresh frame is ready.
            if !fullyClosed && snapshots.isEmpty { return }
        }
        showPanels()
        render(animated: animated)
    }

    private func captureDesktop() {
        cancelCapture()
        let current = generation
        captureTask = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let self, !Task.isCancelled, generation == current else { return }
                let excludedIDs = Set(panels.map { CGWindowID($0.windowNumber) })
                let excluded = content.windows.filter { excludedIDs.contains($0.windowID) }
                let screens = NSScreen.screens
                var images: [CGDirectDisplayID: CGImage] = [:]
                for screen in screens {
                    guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                        throw NSError(domain: "Curtain", code: 1, userInfo: [NSLocalizedDescriptionKey: "A connected display could not be captured."])
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: excluded)
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
                    configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    guard !Task.isCancelled, generation == current, !fullyClosed else { return }
                    images[screen.displayID] = image
                }
                snapshots = images
                captureTask = nil
                if fraction > 0 {
                    showPanels()
                    panels.forEach { $0.setSnapshot(snapshots[$0.displayID]) }
                    render(animated: true)
                }
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                captureTask = nil
                remove()
                style = .sliding
                onCaptureFailure?("Couldn't capture the desktop. Using the sliding curtain. Check Screen Recording access in Settings.")
                // The controller supplies the sliding style's own progress on its next tick.
            }
        }
    }

    private func showPanels() {
        guard panels.isEmpty else { return }
        for screen in NSScreen.screens {
            let panel = CurtainPanel(screen: screen, style: style)
            panel.onDismiss = { [weak self] in self?.onDismiss?() }
            panel.setSnapshot(snapshots[screen.displayID])
            panels.append(panel)
        }
        // Position the content before exposing any windows to avoid a flat-frame flash.
        render(animated: false)
        panels.forEach { $0.orderFrontRegardless() }
        panels.first?.makeKey()
    }

    private func render(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        panels.forEach { $0.render(fraction, rotationDegrees: rotationDegrees, fullyClosed: fullyClosed) }
        CATransaction.commit()
    }

    func hide(animated: Bool = true) {
        cancelCapture()
        guard !panels.isEmpty else { snapshots.removeAll(); return }
        fraction = 0
        rotationDegrees = 0
        fullyClosed = false
        if !animated { remove(); return }
        render(animated: true)
        if style == .perspective {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panels.forEach { $0.animator().alphaValue = 0 }
            }
        }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, generation == current else { return }
            remove()
        }
    }

    func rebuild(fraction: Double) {
        let wasClosed = fullyClosed
        let rotation = rotationDegrees
        begin()
        cover(fraction, rotationDegrees: rotation, fullyClosed: wasClosed)
    }

    private func cancelCapture() {
        generation += 1
        captureTask?.cancel()
        captureTask = nil
    }

    private func remove() {
        cancelCapture()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        snapshots.removeAll()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor
private final class CurtainPanel: NSPanel {
    let displayID: CGDirectDisplayID
    private let style: CurtainStyle
    private let surface = CALayer()
    private let shade = CAGradientLayer()
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, style: CurtainStyle) {
        self.displayID = screen.displayID
        self.style = style
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = style == .perspective ? .black : .clear
        isOpaque = style == .perspective
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = backgroundColor.cgColor
        surface.contentsScale = screen.backingScaleFactor
        surface.bounds = CGRect(origin: .zero, size: screen.frame.size)
        if style == .sliding {
            surface.backgroundColor = NSColor.black.cgColor
            surface.anchorPoint = CGPoint(x: 0.5, y: 1)
            surface.position = CGPoint(x: screen.frame.width / 2, y: screen.frame.height * 2)
        } else {
            // Keep the world screen anchored at the hinge; render through an orbiting camera.
            surface.anchorPoint = CGPoint(x: 0.5, y: 0)
            surface.position = CGPoint(x: screen.frame.width / 2, y: 0)
            surface.isDoubleSided = false
            surface.masksToBounds = true
            surface.contentsGravity = .resize
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.name = "lidBlur"
                blur.setValue(0, forKey: kCIInputRadiusKey)
                surface.filters = [blur]
            }
            surface.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            shade.frame = surface.bounds
            shade.colors = [NSColor.black.withAlphaComponent(0.08).cgColor,
                            NSColor.black.withAlphaComponent(0.75).cgColor]
            shade.startPoint = CGPoint(x: 0.5, y: 0)
            shade.endPoint = CGPoint(x: 0.5, y: 1)
            surface.addSublayer(shade)
        }
        view.layer?.addSublayer(surface)
        contentView = view
    }

    func setSnapshot(_ image: CGImage?) {
        guard style == .perspective else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.contents = image
        CATransaction.commit()
    }

    func render(_ progress: Double, rotationDegrees: Double, fullyClosed: Bool) {
        if style == .sliding {
            surface.position.y = frame.height * (2 - progress)
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var transform = CATransform3DIdentity
        if !reduceMotion {
            let radians = max(0, rotationDegrees) * .pi / 180
            let halfHeight = frame.height / 2
            let distance = frame.height * 1.7
            let sine = sin(radians)
            let cosine = cos(radians)

            // Fixed world screen: (x, y, 0), with the hinge at y = 0.
            // Orbit the camera and its up/forward basis together around that hinge.
            // Its initial position is (0, halfHeight, distance), looking at screen center.
            // In camera coordinates a screen point has:
            // horizontal = x, vertical = y*cos(angle) - halfHeight,
            // depth = distance + y*sin(angle).
            // Project around the viewport CENTER, then convert back to bottom-origin
            // layer coordinates. The halfHeight term is essential: omitting it makes
            // the image slide down independently of the camera.
            transform.m22 = cosine + halfHeight * sine / distance
            transform.m24 = sine / distance
        }
        surface.transform = transform
        surface.setValue(24 * pow(progress, 1.5), forKeyPath: "filters.lidBlur.inputRadius")
        let fade = reduceMotion ? progress : pow(max(0, (progress - 0.82) / 0.18), 2)
        surface.opacity = fullyClosed ? 0 : Float(max(0, 1 - fade))
        surface.cornerRadius = CGFloat(progress * 10)
        surface.borderWidth = CGFloat(progress * 0.5)
        shade.opacity = Float(progress)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onDismiss?() }
        return true
    }
}
