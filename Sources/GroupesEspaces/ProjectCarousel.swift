import AppKit
import QuartzCore

@MainActor
final class ProjectCarousel: NSView {
    static let height: CGFloat = 77

    private let selection = NSView()
    private let settingsButton: NSButton
    private var labels: [NSTextField] = []
    private let rowHeight: CGFloat = 22
    private let settingsWidth: CGFloat = 44

    init(settingsTarget: AnyObject, settingsAction: Selector) {
        let gear = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold)) ?? NSImage()
        settingsButton = NSButton(image: gear, target: settingsTarget, action: settingsAction)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 14
        selection.wantsLayer = true
        selection.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.19).cgColor
        selection.layer?.cornerRadius = 7
        addSubview(selection)

        settingsButton.isBordered = false
        settingsButton.contentTintColor = .white
        settingsButton.wantsLayer = true
        settingsButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.19).cgColor
        settingsButton.layer?.cornerRadius = 8
        settingsButton.toolTip = "Organiser les projets (⌘,)"
        settingsButton.setAccessibilityLabel("Organiser les projets")
        settingsButton.keyEquivalent = ","
        settingsButton.keyEquivalentModifierMask = .command
        addSubview(settingsButton)
    }

    required init?(coder: NSCoder) { nil }

    func isOverSettings(_ windowPoint: NSPoint) -> Bool {
        settingsButton.bounds.contains(settingsButton.convert(windowPoint, from: nil))
    }

    func display(titles: [String], selected index: Int, count: Int, direction: Int) {
        labels.forEach { $0.removeFromSuperview() }
        labels.removeAll(keepingCapacity: true)

        let row = rowFrame(offset: 0)
        selection.frame = row.insetBy(dx: -2, dy: 0)
        settingsButton.frame = NSRect(x: bounds.maxX - 40, y: bounds.midY - 16, width: 32, height: 32)
        let animated = direction != 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let offsets = animated ? (direction > 0 ? -2...1 : -1...2) : -1...1
        for offset in offsets {
            let title = titles[(index + offset + titles.count) % titles.count]
            let label = NSTextField(labelWithString: offset == 0 ? "\(title)  ·  \(count)" : title)
            label.alignment = .center
            label.font = .systemFont(ofSize: 13, weight: offset == 0 ? .semibold : .regular)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            let startingOffset = animated ? offset + direction : offset
            label.frame = rowFrame(offset: startingOffset)
            label.alphaValue = opacity(for: startingOffset)
            addSubview(label)
            labels.append(label)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.19
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for (offset, label) in zip(offsets, labels) {
                    label.animator().frame = rowFrame(offset: offset)
                    label.animator().alphaValue = opacity(for: offset)
                }
            }
        }
    }

    private func rowFrame(offset: Int) -> NSRect {
        NSRect(x: 8, y: bounds.midY - rowHeight / 2 - CGFloat(offset) * rowHeight,
               width: bounds.width - 16 - settingsWidth, height: rowHeight)
    }

    private func opacity(for offset: Int) -> CGFloat {
        switch abs(offset) {
        case 0: 1
        case 1: 0.53
        default: 0
        }
    }
}
