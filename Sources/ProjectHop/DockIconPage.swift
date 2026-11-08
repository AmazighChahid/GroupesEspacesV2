import AppKit

struct DockWindowSection {
    var title: String? = nil
    var projectID: UUID? = nil
    var createsProject = false
    let windows: [DockListRow]
}

@MainActor
final class DockIconPage: NSView {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private struct SectionLayout {
        let section: DockWindowSection
        let firstColumn: Int
        let columns: Int
        let y: CGFloat
        let height: CGFloat
        let rowsPerColumn: Int
        let labelHeight: CGFloat
    }

    private static let hoverGrowth: CGFloat = 0.10

    let headerView: NSView
    let railFrame: NSRect
    private let iconSize: CGFloat
    private var windowTiles: [TileButton] = []

    init(available: NSSize, projectName: String, projectNames: [String], selectedProject: Int?,
         header: DockListRow, controls: [DockListRow], sections: [DockWindowSection],
         selectProject: @escaping (Int) -> Void, createProject: (() -> Void)?,
         dropWindow: @escaping (String, UUID?) -> Bool, dragStarted: @escaping (String, String, NSRect) -> Void, dragEnded: @escaping () -> Void) {
        let inset: CGFloat = 8
        let headerHeight: CGFloat = 53
        let dividerGap: CGFloat = 5
        let controlHeight: CGFloat = 33
        let leadingGap: CGFloat = 5
        let footerHeight: CGFloat = projectNames.isEmpty ? 0 : 18
        iconSize = 60
        let pitch: CGFloat = 66
        let columnWidth = iconSize + 23
        let windowStart = leadingGap + CGFloat(controls.count) * controlHeight
        let fixedHeight = 2 * inset + headerHeight + dividerGap + footerHeight + windowStart
        let displayedSections = createProject == nil ? sections : sections + [DockWindowSection(createsProject: true, windows: [])]
        let layout = Self.layoutSections(displayedSections, availableHeight: available.height - fixedHeight, pitch: pitch)
        let gridWidth = CGFloat(layout.columns) * columnWidth
        let maxWidth = max(columnWidth, available.width - 152)
        let visibleColumns = max(1, Int(maxWidth / columnWidth))
        let railWidth = min(gridWidth, CGFloat(visibleColumns) * columnWidth)
        let height = min(available.height, fixedHeight + layout.height)
        railFrame = NSRect(x: 0, y: 0, width: railWidth, height: height)
        let viewport = NSRect(x: 0, y: inset + footerHeight, width: railWidth,
                              height: max(0, height - 2 * inset - headerHeight - dividerGap - footerHeight))
        let list = DocumentView(frame: NSRect(x: 0, y: 0, width: gridWidth, height: viewport.height))
        let titleButton = TileButton(header, size: 19, caption: projectName)
        headerView = titleButton
        super.init(frame: railFrame)

        titleButton.frame = NSRect(x: inset, y: height - inset - headerHeight,
                                   width: railWidth - 2 * inset, height: headerHeight)
        addSubview(titleButton)

        let divider = NSBox(frame: NSRect(x: 14, y: titleButton.frame.minY - 2, width: railWidth - 28, height: 1))
        divider.boxType = .separator
        addSubview(divider)

        for (index, row) in controls.enumerated() {
            let button = TileButton(row, size: 20)
            button.frame = NSRect(x: gridWidth - columnWidth + inset,
                                  y: leadingGap + CGFloat(index) * controlHeight,
                                  width: columnWidth - 2 * inset, height: controlHeight)
            list.addSubview(button)
        }
        for section in layout.sections {
            let x = gridWidth - CGFloat(section.firstColumn + section.columns) * columnWidth
            let y = windowStart + section.y
            if section.section.createsProject, let createProject {
                let frame = NSRect(x: x, y: y, width: columnWidth, height: section.height)
                let block = ProjectBlock(title: nil, frame: frame)
                let icon = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                let button = TileButton(DockListRow(title: "Nouveau projet", image: icon, action: createProject), size: 14)
                button.frame = block.bounds
                button.toolTip = "Nouveau projet"
                block.addSubview(button)
                list.addSubview(block)
                continue
            }
            let block: ProjectBlock?
            if let title = section.section.title {
                let frame = NSRect(x: x, y: y, width: CGFloat(section.columns) * columnWidth, height: section.height)
                let projectID = section.section.projectID
                let target = ProjectBlock(title: title, frame: frame) { dropWindow($0, projectID) }
                list.addSubview(target)
                block = target
            } else {
                block = nil
            }
            for (offset, row) in section.section.windows.enumerated() {
                guard row.windowKey != nil else { continue }
                let column = section.firstColumn + offset / section.rowsPerColumn
                let index = offset % section.rowsPerColumn
                let tileY = y + section.labelHeight + CGFloat(index) * pitch
                let button = TileButton(row, size: iconSize)
                let frame = NSRect(x: gridWidth - CGFloat(column + 1) * columnWidth,
                                   y: tileY, width: columnWidth, height: pitch)
                button.frame = block.map { frame.offsetBy(dx: -$0.frame.minX, dy: -$0.frame.minY) } ?? frame
                button.gridPosition = NSPoint(x: CGFloat(column), y: tileY / pitch)
                windowTiles.append(button)
                button.dragStarted = dragStarted
                button.dragEnded = dragEnded
                let container: NSView = block.map { $0 as NSView } ?? list
                container.addSubview(button)
            }
        }
        addSubview(Self.horizontalStrip(list, in: viewport, offset: gridWidth - railWidth))
        if !projectNames.isEmpty {
            let footer = NSRect(x: inset, y: inset - 2, width: railWidth - 2 * inset, height: footerHeight)
            addSubview(Self.projectDots(in: footer, names: projectNames, selected: selectedProject, select: selectProject))
        }
    }

    required init?(coder: NSCoder) { nil }

    private static func layoutSections(_ sections: [DockWindowSection], availableHeight: CGFloat, pitch: CGFloat)
        -> (sections: [SectionLayout], columns: Int, height: CGFloat) {
        var placements: [SectionLayout] = []
        var column = 0
        var y: CGFloat = 0
        var width = 1
        var height: CGFloat = 0

        for section in sections where section.createsProject || section.title != nil || !section.windows.isEmpty {
            let labelHeight: CGFloat = section.title == nil ? 0 : 22
            let padding: CGFloat = section.title == nil ? 0 : 4
            let rowsPerColumn = max(1, Int((availableHeight - labelHeight - padding) / pitch))
            let columns = max(1, (section.windows.count + rowsPerColumn - 1) / rowsPerColumn)
            let blockHeight = section.createsProject ? 34
                : labelHeight + CGFloat(min(rowsPerColumn, section.windows.count)) * pitch + padding
            if y > 0, columns > 1 || y + blockHeight > availableHeight {
                column += 1
                y = 0
            }
            placements.append(SectionLayout(section: section, firstColumn: column, columns: columns, y: y,
                                            height: blockHeight, rowsPerColumn: rowsPerColumn, labelHeight: labelHeight))
            width = max(width, column + columns)
            height = max(height, y + blockHeight)
            if columns > 1 {
                column += columns
                y = 0
            } else {
                y += blockHeight + 6
            }
        }
        return (placements, width, height)
    }

    private final class ProjectBlock: NSView {
        private let drop: ((String) -> Bool)?
        private var isDropTarget = false { didSet { needsDisplay = true } }

        override var isFlipped: Bool { true }

        init(title: String?, frame: NSRect, drop: ((String) -> Bool)? = nil) {
            self.drop = drop
            super.init(frame: frame)
            if drop != nil { registerForDraggedTypes([.sideDockWindow]) }
            guard let title else { return }
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 9, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = title
            label.frame = NSRect(x: 9, y: 6, width: frame.width - 18, height: 13)
            addSubview(label)
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            let pixel = 1 / (window?.backingScaleFactor ?? 1)
            let rect = bounds.insetBy(dx: 3 + pixel / 2, dy: pixel / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            let color = isDropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.7)
                : NSColor.labelColor.withAlphaComponent(0.14)
            color.setStroke()
            path.lineWidth = isDropTarget ? 1 : pixel
            path.stroke()
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            isDropTarget = drop != nil && sender.sideDockWindowKey != nil
            return isDropTarget ? .move : []
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            draggingEntered(sender)
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) { isDropTarget = false }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            drop != nil && sender.sideDockWindowKey != nil
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            isDropTarget = false
            guard let key = sender.sideDockWindowKey else { return false }
            return drop?(key) ?? false
        }
    }

    private static func horizontalStrip(_ document: NSView, in frame: NSRect, offset: CGFloat) -> NSView {
        guard document.frame.width > frame.width else {
            document.frame.origin = frame.origin
            return document
        }
        let scroll = NSScrollView(frame: frame)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        return scroll
    }

    private static func projectDots(in frame: NSRect, names: [String], selected: Int?, select: @escaping (Int) -> Void) -> NSView {
        let spacing: CGFloat = 13
        let dotsWidth = CGFloat(names.count) * spacing
        let width = max(frame.width, dotsWidth)
        let dots = NSView(frame: NSRect(x: 0, y: 0, width: width, height: frame.height))
        let start = (width - dotsWidth) / 2
        for (index, name) in names.enumerated() {
            let button = ProjectDot(name: name, active: index == selected) { select(index) }
            button.frame = NSRect(x: start + CGFloat(index) * spacing, y: 0, width: spacing, height: frame.height)
            dots.addSubview(button)
        }
        let center = start + (CGFloat(selected ?? 0) + 0.5) * spacing
        let offset = min(max(0, center - frame.width / 2), width - frame.width)
        return horizontalStrip(dots, in: frame, offset: offset)
    }

    private final class ProjectDot: NSButton {
        private let active: Bool
        private let select: () -> Void

        init(name: String, active: Bool, select: @escaping () -> Void) {
            self.active = active
            self.select = select
            super.init(frame: .zero)
            title = ""
            isBordered = false
            toolTip = name
            setAccessibilityLabel(name)
            if active { setAccessibilityHelp("Projet actif") }
            target = self
            action = #selector(selectProject)
        }

        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let size: CGFloat = active ? 6 : 4
            let rect = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
            NSColor.labelColor.withAlphaComponent(active || isHighlighted ? 0.82 : 0.27).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        @objc private func selectProject() { select() }
    }

    func updateHover(at screenPoint: NSPoint?, animated: Bool) -> (title: String, frame: NSRect)? {
        guard let window else { return nil }
        let tile = screenPoint.flatMap { point in
            window.contentView?.hitTest(window.convertPoint(fromScreen: point)) as? TileButton
        }.flatMap { $0.isDescendant(of: self) ? $0 : nil }
        magnify(around: tile?.gridPosition, animated: animated)
        guard let tile else { return nil }
        return (tile.hoverTitle, window.convertToScreen(tile.convert(tile.iconRect, to: nil)))
    }

    private func magnify(around focus: NSPoint?, animated: Bool) {
        let radius: CGFloat = 1.7
        for tile in windowTiles {
            let distance: CGFloat
            if let focus, let position = tile.gridPosition {
                distance = hypot(position.x - focus.x, position.y - focus.y)
            } else {
                distance = .infinity
            }
            let weight = distance < radius ? (1 + cos(.pi * distance / radius)) / 2 : 0
            let target = iconSize * (1 + Self.hoverGrowth * weight)
            let delta = target - tile.displaySize
            if abs(delta) > 0.04 {
                tile.displaySize += animated ? delta * 0.28 : delta
            } else if tile.displaySize != target {
                tile.displaySize = target
            }
        }
    }

    private final class TileButton: NSButton, NSDraggingSource {
        private let invoke: (() -> Void)?
        private let windowKey: String?
        var isWindow: Bool { windowKey != nil }
        var gridPosition: NSPoint?
        var displaySize: CGFloat { didSet { needsDisplay = true } }
        let hoverTitle: String
        var dragStarted: ((String, String, NSRect) -> Void)?
        var dragEnded: (() -> Void)?
        private var dragAnchor: NSRect?

        var iconRect: NSRect {
            NSRect(x: bounds.midX - displaySize / 2, y: bounds.midY - displaySize / 2, width: displaySize, height: displaySize)
        }

        init(_ row: DockListRow, size: CGFloat, caption: String? = nil) {
            invoke = row.action
            windowKey = row.windowKey
            displaySize = size
            hoverTitle = row.title
            super.init(frame: .zero)
            title = caption ?? ""
            if let icon = row.image?.copy() as? NSImage {
                icon.size = NSSize(width: size, height: size)
                image = icon
            }
            if row.selected { contentTintColor = .controlAccentColor }
            imagePosition = caption == nil ? .imageOnly : .imageAbove
            if caption != nil {
                font = .systemFont(ofSize: 10, weight: .semibold)
                cell?.wraps = true
                cell?.lineBreakMode = .byTruncatingTail
            }
            imageScaling = .scaleProportionallyDown
            isBordered = false
            isEnabled = row.action != nil
            setAccessibilityLabel(row.title)
            setAccessibilityHelp(row.help)
            target = self
            action = #selector(performRowAction)
        }

        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            if isWindow {
                image?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.72 : 1,
                            respectFlipped: true, hints: nil)
            } else {
                super.draw(dirtyRect)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let windowKey, let window, let image else { super.mouseDown(with: event); return }
            highlight(true)
            defer { highlight(false) }
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                              until: .distantFuture, inMode: .eventTracking, dequeue: true) {
                let point = convert(next.locationInWindow, from: nil)
                if next.type == .leftMouseUp {
                    if bounds.contains(point) { performRowAction() }
                    return
                }
                let distance = hypot(next.locationInWindow.x - event.locationInWindow.x,
                                     next.locationInWindow.y - event.locationInWindow.y)
                guard distance >= 5 else { continue }
                let payload = NSPasteboardItem()
                payload.setString(windowKey, forType: .sideDockWindow)
                let item = NSDraggingItem(pasteboardWriter: payload)
                let rect = iconRect
                item.setDraggingFrame(rect, contents: image)
                dragAnchor = window.convertToScreen(convert(rect, to: nil))
                let session = beginDraggingSession(with: [item], event: next, source: self)
                session.animatesToStartingPositionsOnCancelOrFail = true
                return
            }
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            if let windowKey, let dragAnchor { dragStarted?(windowKey, hoverTitle, dragAnchor) }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragAnchor = nil
            dragEnded?()
        }

        @objc private func performRowAction() { invoke?() }
    }
}

extension NSPasteboard.PasteboardType {
    static let sideDockWindow = Self("fr.groupesespaces.v2.window")
}

extension NSDraggingInfo {
    @MainActor var sideDockWindowKey: String? {
        guard draggingSource != nil else { return nil }
        return draggingPasteboard.string(forType: .sideDockWindow)
    }
}
