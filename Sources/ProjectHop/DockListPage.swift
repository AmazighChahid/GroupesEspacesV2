import AppKit

struct DockListRow {
    let title: String
    let image: NSImage?
    var help: String? = nil
    var selected = false
    var windowKey: String? = nil
    var dropWindow: ((String) -> Bool)? = nil
    var action: (() -> Void)? = nil
    var deleteProject: (() -> Void)? = nil
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
            let frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: bodyWidth, height: rowHeight)
            list.addSubview(RowView(row, frame: frame))
        }
        scroll.documentView = list
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { nil }

    private final class ActionButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class RowView: NSView {
        private let button = ActionButton()
        private let trash: ActionButton?
        private let invoke: (() -> Void)?
        private let selected: Bool
        private let dropWindow: ((String) -> Bool)?
        private let deleteProject: (() -> Void)?
        private var hovered = false {
            didSet {
                needsDisplay = true
                trash?.isHidden = !hovered
            }
        }

        init(_ row: DockListRow, frame: NSRect) {
            invoke = row.action
            selected = row.selected
            dropWindow = row.dropWindow
            deleteProject = row.deleteProject
            trash = row.deleteProject.map { _ in ActionButton() }
            super.init(frame: frame)
            button.frame = bounds
            button.title = row.title
            button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            if let icon = row.image?.copy() as? NSImage {
                icon.size = NSSize(width: 19, height: 19)
                button.image = icon
            }
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.alignment = .left
            button.cell?.usesSingleLineMode = true
            button.cell?.lineBreakMode = .byTruncatingTail
            button.isBordered = false
            button.isEnabled = row.action != nil || row.dropWindow != nil
            button.toolTip = row.help ?? row.title
            button.setAccessibilityLabel(row.help ?? row.title)
            button.target = self
            button.action = #selector(performRowAction)
            addSubview(button)
            if let trash {
                let label = "Supprimer le projet \(row.title)"
                trash.frame = NSRect(x: bounds.maxX - 29, y: bounds.midY - 13, width: 26, height: 26)
                button.frame.size.width = trash.frame.minX
                trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
                trash.imagePosition = .imageOnly
                trash.isBordered = false
                trash.contentTintColor = .systemRed
                trash.toolTip = label
                trash.setAccessibilityLabel(label)
                trash.target = self
                trash.action = #selector(performDelete)
                trash.isHidden = true
                addSubview(trash)
            }
            if dropWindow != nil { registerForDraggedTypes([.sideDockWindow]) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        required init?(coder: NSCoder) { nil }

        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }

        override func draw(_ dirtyRect: NSRect) {
            if selected || (hovered && button.isEnabled) {
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
        @objc private func performDelete() { deleteProject?() }
    }
}
