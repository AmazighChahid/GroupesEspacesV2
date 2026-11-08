import AppKit

@MainActor
final class ProjectBadge: NSView {
    static let height: CGFloat = 34

    private let label = NSTextField(labelWithString: "")
    private let settingsButton: NSButton

    init(settingsTarget: AnyObject, settingsAction: Selector) {
        let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold)) ?? NSImage()
        settingsButton = NSButton(image: gear, target: settingsTarget, action: settingsAction)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        layer?.cornerRadius = Self.height / 2

        label.alignment = .left
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        settingsButton.isBordered = false
        settingsButton.contentTintColor = .white
        settingsButton.toolTip = "Organiser les projets (⌘,)"
        settingsButton.setAccessibilityLabel("Organiser les projets")
        settingsButton.isHidden = true
        addSubview(settingsButton)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    func display(title: String, count: Int, above bezel: CGRect) {
        label.stringValue = "\(title)  ·  \(count)"
        let labelWidth = min(220, ceil(label.intrinsicContentSize.width))
        let width = labelWidth + 44
        frame = CGRect(x: bezel.midX - width / 2, y: bezel.maxY + 6, width: width, height: Self.height).integral
        label.frame = CGRect(x: 12, y: 8, width: labelWidth, height: 18)
        settingsButton.frame = CGRect(x: width - 30, y: 4, width: 25, height: 26)
        updateHover()
    }

    func contains(_ windowPoint: NSPoint) -> Bool {
        !isHidden && bounds.contains(convert(windowPoint, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { settingsButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { settingsButton.isHidden = true }

    private func updateHover() {
        guard let window else { return }
        settingsButton.isHidden = !contains(window.mouseLocationOutsideOfEventStream)
    }
}
