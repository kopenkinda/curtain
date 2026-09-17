import AppKit
import QuartzCore

@MainActor
final class CurtainOverlay {
    private var panels: [NSPanel] = []
    private var generation = 0
    var onDismiss: (() -> Void)?

    func cover(_ fraction: Double, animated: Bool = false) {
        generation += 1
        if panels.isEmpty {
            for screen in NSScreen.screens {
                let panel = CurtainPanel(contentRect: screen.frame,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.onDismiss = { [weak self] in self?.onDismiss?() }
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = false
                let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.wantsLayer = true
                view.layer?.masksToBounds = true
                let curtain = CALayer()
                curtain.backgroundColor = NSColor.black.cgColor
                curtain.anchorPoint = CGPoint(x: 0.5, y: 1)
                curtain.frame = CGRect(x: 0, y: screen.frame.height, width: screen.frame.width, height: screen.frame.height)
                view.layer?.addSublayer(curtain)
                panel.contentView = view
                panels.append(panel)
                panel.orderFrontRegardless()
            }
        }
        if fraction > 0, !panels.contains(where: { $0.isKeyWindow }) {
            panels.first?.makeKey()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for panel in panels {
            guard let layer = panel.contentView?.layer?.sublayers?.first else { continue }
            layer.position.y = panel.frame.height * (2 - min(1, max(0, fraction)))
        }
        CATransaction.commit()
    }

    func hide(animated: Bool = true) {
        guard !panels.isEmpty else { return }
        cover(0, animated: animated)
        let current = generation
        if !animated { remove(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, generation == current else { return }
            remove()
        }
    }

    func rebuild(fraction: Double) {
        remove()
        cover(fraction)
    }

    private func remove() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

@MainActor
private final class CurtainPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() }
        // Do not send keystrokes into applications hidden behind the curtain.
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onDismiss?() }
        return true
    }
}
