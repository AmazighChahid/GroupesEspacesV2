import AppKit
import QuartzCore

@MainActor
final class DockProjectPicker {
    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private var anchor = NSRect.zero
    private var transition = 0
    private(set) var hoverRegion: NSRect?

    init() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.hasShadow = true
        glass.cornerRadius = 20
        glass.contentView = content
        panel.contentView = glass
    }

    func show(rows: [DockListRow], from source: NSRect, beside dock: NSRect, in bounds: NSRect, animated: Bool) {
        let area = bounds.insetBy(dx: 8, dy: 8)
        let width = min(210, dock.minX - area.minX - 8)
        guard width >= 115 else { return }
        let page = DockListPage(width: width, maxHeight: area.height, rows: rows)
        let height = page.frame.height
        let y = min(max(source.maxY + 8 - height, area.minY), area.maxY - height)
        let frame = NSRect(x: dock.minX - width - 8, y: y, width: width, height: height)
        anchor = NSRect(x: source.minX, y: source.midY - 16, width: 45, height: 32)
        hoverRegion = frame.insetBy(dx: -9, dy: -9)
        transition += 1

        content.subviews.forEach { $0.removeFromSuperview() }
        panel.setFrame(animated ? anchor : frame, display: true)
        page.frame.origin.y = content.bounds.maxY - height
        page.autoresizingMask = [.minYMargin]
        page.alphaValue = animated ? 0 : 1
        content.addSubview(page)
        panel.alphaValue = animated ? 0 : 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PanelMotion.morphDuration
                context.timingFunction = PanelMotion.easeOut
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
                page.animator().alphaValue = 1
            }
        }
    }

    func close(animated: Bool) {
        hoverRegion = nil
        panel.ignoresMouseEvents = true
        transition += 1
        let currentTransition = transition
        guard panel.isVisible else { return }
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.17
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(anchor, display: true)
            panel.animator().alphaValue = 0
            content.subviews.first?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.transition == currentTransition else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
