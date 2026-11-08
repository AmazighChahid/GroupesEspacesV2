import AppKit

struct DockListRow {
    let title: String
    let image: NSImage?
    var help: String? = nil
    var selected = false
    var windowKey: String? = nil
    var dropWindow: ((String) -> Bool)? = nil
    var action: (() -> Void)? = nil
}

@MainActor
final class DockListPage: NSView {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    init(width: CGFloat, maxHeight: CGFloat, rows: [DockListRow]) {
        let inset: CGFloat = 8
        let rowHeight: CGFloat = 35
        let bodyWidth = width - 2 * inset
        let bodyHeight = CGFloat(rows.count) * rowHeight
        let height = min(maxHeight, bodyHeight + 2 * inset)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let viewport = NSRect(x: inset, y: inset, width: bodyWidth, height: max(0, height - 2 * inset))
        let scroll = NSScrollView(frame: viewport)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = bodyHeight > viewport.height
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let list = DocumentView(frame: NSRect(x: 0, y: 0, width: bodyWidth, height: bodyHeight))
        for (index, row) in rows.enumerated() {
            let button = RowButton(row)
            button.frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: bodyWidth, height: rowHeight)
            list.addSubview(button)
        }
        scroll.documentView = list
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { nil }

    private final class RowButton: NSButton {
        private let invoke: (() -> Void)?
        private let selected: Bool
        private let dropWindow: ((String) -> Bool)?
        private var hovered = false { didSet { needsDisplay = true } }

        init(_ row: DockListRow) {
            invoke = row.action
            selected = row.selected
            dropWindow = row.dropWindow
            super.init(frame: .zero)
            title = row.title
            font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            if let icon = row.image?.copy() as? NSImage {
                icon.size = NSSize(width: 19, height: 19)
                image = icon
            }
            imagePosition = .imageLeft
            imageScaling = .scaleProportionallyDown
            alignment = .left
            cell?.usesSingleLineMode = true
            cell?.lineBreakMode = .byTruncatingTail
            isBordered = false
            isEnabled = row.action != nil || row.dropWindow != nil
            if dropWindow != nil { registerForDraggedTypes([.sideDockWindow]) }
            toolTip = row.help ?? row.title
            setAccessibilityLabel(row.help ?? row.title)
            target = self
            action = #selector(performRowAction)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }

        override func draw(_ dirtyRect: NSRect) {
            if selected || (hovered && isEnabled) {
                NSColor.labelColor.withAlphaComponent(selected ? 0.15 : 0.09).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 9, yRadius: 9).fill()
            }
            super.draw(dirtyRect)
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            hovered = windowKey(in: sender) != nil
            return hovered ? .move : []
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            draggingEntered(sender)
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) { hovered = false }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            windowKey(in: sender) != nil
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            hovered = false
            guard let key = windowKey(in: sender) else { return false }
            return dropWindow?(key) ?? false
        }

        private func windowKey(in sender: any NSDraggingInfo) -> String? {
            guard dropWindow != nil else { return nil }
            return sender.sideDockWindowKey
        }

        @objc private func performRowAction() { invoke?() }
    }
}
