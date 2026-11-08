import AppKit
import QuartzCore

@MainActor
final class SideDockController: NSObject {
    private enum WindowFilter: Equatable {
        case all
        case unassigned
        case project(UUID)
    }

    private let workspace = NSWorkspace.shared
    private let panel = DockPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    private let surface = NSView()
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private let picker = DockProjectPicker()
    private let windowLabel = DockWindowLabel()
    private let store: GroupStore
    private let activate: (SpaceWindow) -> Void
    private let authorize: () -> Void
    private let canReveal: () -> Bool
    private var windowFilter = WindowFilter.all
    private var currentPage: DockIconPage?
    private var windowIcons: [pid_t: NSImage] = [:]
    private var dockFrame: NSRect?
    private var hoverRegion: NSRect?
    private var selectionRegion: NSRect?
    private var screens: [NSScreen] = []
    private var timer: Timer?
    private var edgeSince: TimeInterval?
    private var outsideSince: TimeInterval?
    private var transition = 0
    private var waitForEdgeExit = false
    private var isNamingProject = false
    private var carouselUntil: TimeInterval = 0
    private var draggedWindowKey: String?
    private var didMoveDraggedWindow = false

    var isBusy: Bool { isNamingProject || draggedWindowKey != nil }

    init(store: GroupStore, activate: @escaping (SpaceWindow) -> Void,
         authorize: @escaping () -> Void, canReveal: @escaping () -> Bool) {
        self.store = store
        self.activate = activate
        self.authorize = authorize
        self.canReveal = canReveal
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.hasShadow = false
        let radius: CGFloat = 23
        surface.wantsLayer = true
        surface.layer?.cornerRadius = radius
        surface.layer?.masksToBounds = true
        glass.cornerRadius = radius
        glass.frame = surface.bounds
        glass.autoresizingMask = [.width, .height]
        glass.contentView = content
        surface.addSubview(glass)
        panel.contentView = surface
        panel.changeProject = { [weak self] in self?.stepProject($0) }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (timer != nil) else { return }
        if enabled {
            screens = NSScreen.screens
            NotificationCenter.default.addObserver(
                self, selector: #selector(screensChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
            startPointerTracking(open: false)
        } else {
            dismiss()
            timer?.invalidate()
            timer = nil
            NotificationCenter.default.removeObserver(self)
        }
    }

    private func startPointerTracking(open: Bool) {
        timer?.invalidate()
        let interval = 1.0 / (open ? 60.0 : 30.0)
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(trackPointer), userInfo: nil, repeats: true)
        timer.tolerance = interval * 0.12
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func trackPointer() {
        guard !isNamingProject else { return }
        guard canReveal() else {
            if dockFrame != nil { dismiss() }
            edgeSince = nil
            return
        }
        let point = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        if let hoverRegion {
            let allowHover = picker.hoverRegion == nil && draggedWindowKey == nil && now >= carouselUntil
            let tile = currentPage?.updateHover(at: allowHover ? point : nil,
                                                animated: PanelMotion.isEnabled)
            if let tile, let dockFrame, let screen = panel.screen {
                windowLabel.show(tile.title, leftOf: min(dockFrame.minX, tile.frame.minX),
                                 tileCenterY: tile.frame.midY, on: screen)
            } else {
                windowLabel.hide()
            }
            let overDock = hoverRegion.contains(point) || tile != nil
            panel.ignoresMouseEvents = !overDock && draggedWindowKey == nil
            if selectionRegion?.contains(point) == false { selectionRegion = nil }
            if overDock || picker.hoverRegion?.contains(point) == true || selectionRegion != nil || draggedWindowKey != nil {
                outsideSince = nil
            } else if let outsideSince {
                if now - outsideSince >= 0.18 { hide(animated: true) }
            } else {
                outsideSince = now
            }
            return
        }

        guard let screen = rightEdgeScreen(at: point) else {
            edgeSince = nil
            waitForEdgeExit = false
            return
        }
        guard !waitForEdgeExit, NSEvent.pressedMouseButtons == 0 else {
            edgeSince = nil
            return
        }
        if let edgeSince {
            if now - edgeSince >= 0.17 { show(on: screen, near: point.y) }
        } else {
            edgeSince = now
        }
    }

    private func rightEdgeScreen(at point: NSPoint) -> NSScreen? {
        guard let screen = screens.first(where: { $0.frame.contains(point) }),
              point.x >= screen.frame.maxX - 2 else { return nil }
        let usable = screen.visibleFrame.insetBy(dx: 0, dy: 12)
        guard point.y >= usable.minY, point.y < usable.maxY else { return nil }
        let acrossEdge = NSPoint(x: screen.frame.maxX + 0.5, y: point.y)
        guard !screens.contains(where: { $0.frame.contains(acrossEdge) }) else { return nil }
        return screen
    }

    private func show(on screen: NSScreen, near pointerY: CGFloat) {
        store.refresh(includeWindows: true)
        windowIcons.removeAll(keepingCapacity: true)
        if case let .project(id) = windowFilter, !store.groups.contains(where: { $0.id == id }) {
            windowFilter = .all
        }
        renderDock(on: screen, near: pointerY)
    }

    private func renderDock(on screen: NSScreen, near pointerY: CGFloat? = nil, slide: Int? = nil) {
        let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        guard area.width >= 150, area.height >= 94 else { return }
        windowLabel.hide()
        let page = makePage(available: area.size)
        let size = page.frame.size
        let previousFrame = dockFrame
        let centerY = pointerY ?? (slide == nil ? previousFrame?.midY ?? area.midY : NSEvent.mouseLocation.y)
        func originY(for height: CGFloat) -> CGFloat {
            min(max(centerY - height / 2, area.minY), area.maxY - height)
        }
        let frame = NSRect(x: area.maxX - size.width, y: originY(for: size.height),
                           width: size.width, height: size.height)
        let rail = page.railFrame.offsetBy(dx: frame.minX, dy: frame.minY)
        hoverRegion = NSRect(x: rail.minX - 9, y: rail.minY - 9,
                             width: screen.frame.maxX - rail.minX + 10, height: rail.height + 18)
        dockFrame = rail
        outsideSince = nil
        transition += 1

        let previous = currentPage
        for view in content.subviews where view !== previous { view.removeFromSuperview() }
        currentPage = page
        let animate = PanelMotion.isEnabled
        if previousFrame == nil {
            previous?.removeFromSuperview()
            panel.setFrame(animate ? frame.offsetBy(dx: 6, dy: 0) : frame, display: true)
            attach(page)
            panel.alphaValue = animate ? 0 : 1
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panel.makeKey()
            startPointerTracking(open: true)
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                    panel.animator().alphaValue = 1
                }
            }
        } else if animate, let slide, let previous {
            let initial = panel.frame
            let y = originY(for: initial.height)
            if initial.minY != y { panel.setFrameOrigin(NSPoint(x: initial.minX, y: y)) }
            attach(page)
            animateCarousel(from: previous, to: page, direction: slide, frame: frame)
        } else if animate {
            attach(page)
            page.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                if panel.frame != frame { panel.animator().setFrame(frame, display: true) }
                previous?.animator().alphaValue = 0
                page.animator().alphaValue = 1
            } completionHandler: {
                DispatchQueue.main.async { previous?.removeFromSuperview() }
            }
        } else {
            previous?.removeFromSuperview()
            panel.setFrame(frame, display: true)
            attach(page)
        }
    }

    private func animateCarousel(from previous: DockIconPage, to page: DockIconPage, direction: Int, frame: NSRect) {
        let duration = PanelMotion.slideDuration
        let generation = transition
        let distance = max(previous.frame.width, page.frame.width) * CGFloat(direction)
        let outgoing = previous.layer?.presentation()?.transform.m41 ?? 0
        carouselUntil = CACurrentMediaTime() + duration

        previous.wantsLayer = true
        page.wantsLayer = true
        PanelMotion.slide(on: previous.layer, axis: .x, from: outgoing, to: -distance, holdsEnd: true)
        PanelMotion.slide(on: page.layer, axis: .x, from: distance)
        if panel.frame != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = PanelMotion.easeOut
                panel.animator().setFrame(frame, display: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            previous.removeFromSuperview()
            if self?.transition == generation { page.layer?.removeAnimation(forKey: PanelMotion.slideKey) }
        }
    }

    private func attach(_ page: DockIconPage) {
        page.frame.origin = NSPoint(
            x: content.bounds.maxX - page.frame.width, y: content.bounds.midY - page.frame.height / 2
        )
        page.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        content.addSubview(page)
    }

    private func makePage(available: NSSize) -> DockIconPage {
        let projects = store.groups
        let names = WindowNames.labels(for: store.windows?.all ?? [], customNames: store.windowNames,
                                       includeApplicationName: false)
        func row(for window: SpaceWindow) -> DockListRow {
            let pid = window.ownerPID
            let icon = windowIcons[pid] ?? NSRunningApplication(processIdentifier: pid)?.icon
            windowIcons[pid] = icon
            return DockListRow(title: names[window.key] ?? window.appName, image: icon ?? Self.symbol("macwindow"),
                               windowKey: window.key, action: { [weak self] in self?.openWindow(window) })
        }

        let filterName: String?
        let sections: [DockWindowSection]
        switch windowFilter {
        case .all:
            filterName = nil
            let destinations = projects.map { (name: $0.name, id: Optional($0.id)) } + [(name: "Sans projet", id: nil)]
            let groups = store.windowsByProject(for: destinations.map(\.id))
            sections = zip(destinations, groups).compactMap { destination, windows in
                if destination.id == nil, store.windows?.count ?? 0 == 0 { return nil }
                return DockWindowSection(title: destination.name, projectID: destination.id, windows: windows.map(row(for:)))
            }
        case .unassigned:
            filterName = "Sans projet"
            sections = [DockWindowSection(windows: store.projectWindows(in: nil).map(row(for:)))]
        case .project(let id):
            filterName = projects.first { $0.id == id }?.name
            sections = [DockWindowSection(windows: store.projectWindows(in: id).map(row(for:)))]
        }

        var controls: [DockListRow] = []
        if sections.allSatisfy({ $0.windows.isEmpty }) {
            controls.append(DockListRow(title: "Aucune fenêtre ouverte", image: Self.symbol("macwindow")))
        }
        if let message = store.message {
            if WindowFocus.isTrusted {
                controls.insert(DockListRow(title: message, image: Self.symbol("info.circle")), at: 0)
            } else {
                controls.insert(DockListRow(title: "Accessibilité requise", image: Self.symbol("accessibility"),
                                        help: message, action: authorize), at: 0)
            }
        }
        let header = DockListRow(title: filterName.map { "Projets · \($0)" } ?? "Projets",
                                 image: Self.symbol("rectangle.3.group.fill"),
                                 help: "Filtrer les fenêtres par projet", selected: filterName != nil, action: { [weak self] in
            self?.toggleProjects()
        })
        let selectedProject = projects.firstIndex { windowFilter == .project($0.id) }
        return DockIconPage(available: available, projectName: filterName ?? "Toutes les fenêtres",
                            projectNames: projects.map(\.name), selectedProject: selectedProject, header: header, controls: controls, sections: sections,
                            selectProject: { [weak self] index in self?.selectFilter(.project(projects[index].id)) },
                            createProject: windowFilter == .all ? { [weak self] in self?.createProject() } : nil,
                            dropWindow: { [weak self] key, project in
                                self?.moveWindow(key, to: project.map(WindowFilter.project) ?? .unassigned) ?? false
                            },
                            dragStarted: { [weak self] in self?.beginWindowDrag(key: $0, title: $1, anchor: $2) },
                            dragEnded: { [weak self] in self?.endWindowDrag() })
    }

    private func toggleProjects() {
        guard draggedWindowKey == nil else { return }
        if picker.hoverRegion != nil {
            picker.close(animated: PanelMotion.isEnabled)
            return
        }
        guard let header = currentPage?.headerView else { return }
        showPicker(from: panel.convertToScreen(header.convert(header.bounds, to: nil)))
    }

    private func showPicker(from source: NSRect, dragTitle: String? = nil) {
        guard let frame = dockFrame, let screen = panel.screen else { return }
        let groups = store.groups
        var rows = [filterRow("Toutes les fenêtres", symbol: "macwindow.on.rectangle", filter: .all)]
        if let dragTitle {
            rows = [DockListRow(title: dragTitle, image: Self.symbol("macwindow"), help: dragTitle)]
        }
        rows += groups.map { filterRow($0.name, symbol: "folder", filter: .project($0.id), dragging: dragTitle != nil) }
        rows.append(filterRow("Sans projet", symbol: "tray", filter: .unassigned, dragging: dragTitle != nil))
        if dragTitle == nil {
            rows.append(DockListRow(title: "Nouveau projet…", image: Self.symbol("plus"), action: { [weak self] in
                self?.createProject()
            }))
        }
        selectionRegion = nil
        windowLabel.hide()
        picker.show(rows: rows, from: source, beside: frame, in: screen.visibleFrame,
                    animated: PanelMotion.isEnabled)
    }

    private func createProject() {
        guard dockFrame != nil, draggedWindowKey == nil, !isNamingProject else { return }
        isNamingProject = true
        defer { isNamingProject = false }
        selectionRegion = picker.hoverRegion ?? hoverRegion
        picker.close(animated: false)
        windowLabel.hide()

        let alert = NSAlert()
        alert.messageText = "Nouveau projet"
        alert.addButton(withTitle: "Créer")
        alert.addButton(withTitle: "Annuler")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.placeholderString = "Nom du projet"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        let previousApp = workspace.frontmostApplication
        NSApp.activate()
        let response = alert.runModal()
        previousApp?.activate()

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
        _ = store.addGroup(named: name)
        if dockFrame != nil, let screen = panel.screen {
            renderDock(on: screen)
        }
    }

    private func filterRow(_ title: String, symbol: String, filter: WindowFilter, dragging: Bool = false) -> DockListRow {
        let image = Self.symbol(symbol)
        if dragging {
            return DockListRow(title: title, image: image, dropWindow: { [weak self] in
                self?.moveWindow($0, to: filter) ?? false
            })
        }
        return DockListRow(title: title, image: image, selected: windowFilter == filter, action: { [weak self] in
            self?.selectFilter(filter)
        })
    }

    private func selectFilter(_ filter: WindowFilter, direction: Int? = nil) {
        guard let screen = panel.screen, dockFrame != nil else { return }
        if let pickerRegion = picker.hoverRegion {
            selectionRegion = pickerRegion
        } else if selectionRegion?.contains(NSEvent.mouseLocation) != true {
            selectionRegion = hoverRegion
        }
        picker.close(animated: PanelMotion.isEnabled)
        guard windowFilter != filter else { return }
        let filters = availableFilters
        let current = filters.firstIndex(of: windowFilter) ?? 0
        let destination = filters.firstIndex(of: filter) ?? 0
        let slide = direction ?? (destination >= current ? 1 : -1)
        windowFilter = filter
        store.message = nil
        renderDock(on: screen, slide: slide)
    }

    private var availableFilters: [WindowFilter] {
        [.all] + store.groups.map { .project($0.id) } + [.unassigned]
    }

    private func stepProject(_ direction: Int) {
        guard dockFrame != nil, draggedWindowKey == nil else { return }
        let filters = availableFilters
        let index = filters.firstIndex(of: windowFilter) ?? 0
        selectFilter(filters[(index + direction + filters.count) % filters.count], direction: direction)
    }

    private func beginWindowDrag(key: String, title: String, anchor: NSRect) {
        guard dockFrame != nil else { return }
        draggedWindowKey = key
        didMoveDraggedWindow = false
        if windowFilter == .all {
            windowLabel.hide()
            picker.close(animated: false)
        } else {
            showPicker(from: anchor, dragTitle: title)
        }
    }

    private func moveWindow(_ key: String, to filter: WindowFilter) -> Bool {
        guard draggedWindowKey == key else { return false }
        let project: UUID?
        switch filter {
        case .project(let id): project = id
        case .unassigned: project = nil
        case .all: return false
        }
        store.refresh(includeWindows: true)
        guard store.assignWindow(key, to: project) else { return false }
        didMoveDraggedWindow = true
        return true
    }

    private func endWindowDrag() {
        guard draggedWindowKey != nil else { return }
        draggedWindowKey = nil
        let moved = didMoveDraggedWindow
        didMoveDraggedWindow = false
        selectionRegion = picker.hoverRegion ?? hoverRegion
        picker.close(animated: PanelMotion.isEnabled)
        if moved, dockFrame != nil, let screen = panel.screen {
            store.message = nil
            renderDock(on: screen)
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
    }

    private func hide(animated: Bool) {
        windowLabel.hide()
        picker.close(animated: animated && PanelMotion.isEnabled)
        hoverRegion = nil
        selectionRegion = nil
        draggedWindowKey = nil
        didMoveDraggedWindow = false
        carouselUntil = 0
        if dockFrame != nil { startPointerTracking(open: false) }
        dockFrame = nil
        edgeSince = nil
        outsideSince = nil
        transition += 1
        let currentTransition = transition
        panel.ignoresMouseEvents = true
        guard panel.isVisible else { return }
        guard animated, PanelMotion.isEnabled else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.transition == currentTransition else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    func dismiss() {
        hide(animated: false)
        waitForEdgeExit = true
    }

    @objc private func screensChanged() {
        screens = NSScreen.screens
        dismiss()
    }

    private func openWindow(_ window: SpaceWindow) {
        activate(window)
        if store.message != nil, dockFrame != nil, let screen = panel.screen {
            picker.close(animated: false)
            renderDock(on: screen)
        }
    }
}
