import AppKit

@MainActor
final class DockWindowLabel {
    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    private let material = NSVisualEffectView()
    private let outline = OutlineView()
    private let label = NSTextField(labelWithString: "")
    private let labelFont = NSFont.systemFont(ofSize: 14)

    init() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.addSubview(outline)
        label.font = labelFont
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        outline.addSubview(label)
        panel.contentView = material
    }

    func show(_ title: String, leftOf leftEdge: CGFloat, tileCenterY: CGFloat, on screen: NSScreen) {
        let height: CGFloat = 30
        let tipWidth: CGFloat = 7
        let padding: CGFloat = 12
        let right = leftEdge - 5
        let area = screen.visibleFrame
        let available = right - area.minX - 4
        guard available > 2 * padding + tipWidth else { hide(); return }
        let previousTitle = label.stringValue
        if previousTitle != title { label.stringValue = title }
        let textSize = label.intrinsicContentSize
        let width = min(available, ceil(textSize.width) + 6 + 2 * padding + tipWidth)
        let y = min(max(tileCenterY - height / 2, area.minY), area.maxY - height)
        let frame = NSRect(x: right - width, y: y, width: width, height: height)
        guard !panel.isVisible || panel.frame != frame || previousTitle != title else { return }

        panel.setFrame(frame, display: false)
        outline.frame = NSRect(origin: .zero, size: frame.size)
        let shape = Self.shape(size: frame.size, tipWidth: tipWidth,
                               tipY: min(max(tileCenterY - y, 8), height - 8))
        material.maskImage = NSImage(size: frame.size, flipped: false) { _ in
            NSColor.white.setFill()
            shape.fill()
            return true
        }
        outline.path = shape
        label.frame = NSRect(x: padding, y: floor((height - textSize.height) / 2),
                             width: width - tipWidth - 2 * padding, height: textSize.height)
        panel.orderFrontRegardless()
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    private static func shape(size: NSSize, tipWidth: CGFloat, tipY: CGFloat) -> NSBezierPath {
        let left: CGFloat = 0.5
        let right = size.width - tipWidth - 0.5
        let bottom: CGFloat = 0.5
        let top = size.height - 0.5
        let radius: CGFloat = 10
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left + radius, y: bottom))
        path.appendArc(withCenter: NSPoint(x: right - radius, y: bottom + radius), radius: radius,
                       startAngle: 270, endAngle: 360)
        let join = min(max(tipY, bottom + radius + 4), top - radius - 4)
        path.line(to: NSPoint(x: right, y: join - 4))
        path.curve(to: NSPoint(x: size.width - 1, y: tipY),
                   controlPoint1: NSPoint(x: right + 1, y: join - 2),
                   controlPoint2: NSPoint(x: size.width - 2, y: tipY - 1))
        path.curve(to: NSPoint(x: right, y: join + 4),
                   controlPoint1: NSPoint(x: size.width - 2, y: tipY + 1),
                   controlPoint2: NSPoint(x: right + 1, y: join + 2))
        path.appendArc(withCenter: NSPoint(x: right - radius, y: top - radius), radius: radius,
                       startAngle: 0, endAngle: 90)
        path.appendArc(withCenter: NSPoint(x: left + radius, y: top - radius), radius: radius,
                       startAngle: 90, endAngle: 180)
        path.appendArc(withCenter: NSPoint(x: left + radius, y: bottom + radius), radius: radius,
                       startAngle: 180, endAngle: 270)
        path.close()
        return path
    }

    private final class OutlineView: NSView {
        var path = NSBezierPath() { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.withAlphaComponent(0.26).setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.48).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
