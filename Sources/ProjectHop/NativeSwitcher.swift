import AppKit
import Carbon
import CoreGraphics
import QuartzCore
import UniformTypeIdentifiers

@MainActor
final class NativeSwitcher: NSObject, NSSearchFieldDelegate {
    enum Filter: Equatable {
        case all, project(UUID), unassigned
    }

    enum ArrowAction {
        case window(Int), project(Int)

        init?(_ key: Int) {
            switch key {
            case kVK_LeftArrow, kVK_Home: self = .window(-1)
            case kVK_RightArrow, kVK_End: self = .window(1)
            case kVK_UpArrow, kVK_PageUp: self = .project(-1)
            case kVK_DownArrow, kVK_PageDown: self = .project(1)
            default: return nil
            }
        }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private struct RemoveBadge {
        let button: NSButton
        let iconFrame: CGRect
    }

    private let store: GroupStore
    private let activate: (SpaceWindow) -> Void
    private let report: (String) -> Void
    private let organize: (CGRect?) -> Void
    private var panel: Panel?
    private var host: NSView?
    private var projectBadge: ProjectBadge?
    private var searchButton: NSButton?
    private var searchField: NSSearchField?
    private var removeBadges: [RemoveBadge] = []
    private var searching = false
    private var scrollDistance = CGPoint.zero
    private var scrollHandled = false
    private var emptyLabel: NSTextField?
    private var renderer: GELayerRenderer?
    private var entries: [SpaceWindow] = []
    private var filter: Filter = .all
    private var foreground: (pid: pid_t, windowID: CGWindowID?)?
    private var selected = 0
    private var localMonitor: Any?
    private var outsideMonitor: Any?
    private var releaseTimer: Timer?
    private var confirmOnRelease = false
    private var selectedByHover = false
    private var lastPointerLocation: CGPoint?

    init(store: GroupStore, activate: @escaping (SpaceWindow) -> Void,
         report: @escaping (String) -> Void, organize: @escaping (CGRect?) -> Void) {
        self.store = store
        self.activate = activate
        self.report = report
        self.organize = organize
    }

    func shortcut(backwards: Bool) {
        if panel?.isVisible == true {
            move(backwards ? -1 : 1)
            if searching { return }
            confirmOnRelease = true
        } else {
            store.refresh(includeWindows: true)
            prioritizeForeground(adjustFilter: true)
            selected = 0
            guard present() else { return }
        }
        guard releaseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) else { return }
                self?.shortcutModifierReleased()
            }
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    func show(filter: Filter? = nil) -> Bool {
        dismiss()
        store.refresh(includeWindows: true)
        self.filter = filter ?? preferredProject()
        prioritizeForeground(adjustFilter: filter == nil)
        selected = 0
        return present()
    }

    private func prioritizeForeground(adjustFilter: Bool) {
        foreground = nil
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let appWindows = windows(for: .all).filter { $0.ownerPID == pid }
        guard !appWindows.isEmpty else { return }
        let activeWindows = appWindows.filter { store.location(for: $0)?.isActive != false }
        let activeIDs = Set(activeWindows.map(\.id))
        let visibleIDs = WindowFocus.visibleWindowIDs(pid: pid).filter { activeIDs.contains($0) }
        // AX can report a focused window on a different Space after AXRaise.
        let focusedID = WindowFocus.focusedWindowID(pid: pid).flatMap { visibleIDs.contains($0) ? $0 : nil }
            ?? visibleIDs.first
        let focused = activeWindows.first { $0.id == focusedID }
            ?? (activeWindows.count == 1 ? activeWindows.first : nil)
        foreground = (pid, focused?.id)
        if adjustFilter, !windows(for: filter).contains(where: { window in
            window.ownerPID == pid && (focused == nil || window.id == focused?.id)
        }) {
            filter = .all
        }
    }

    func dismiss() {
        cancelRelease()
        panel?.orderOut(nil)
        resetScroll()
        lastPointerLocation = nil
        searching = false
        searchField?.stringValue = ""
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        localMonitor = nil
        outsideMonitor = nil
    }

    var isVisible: Bool { panel?.isVisible == true }

    var selectedWindow: SpaceWindow? { entries.indices.contains(selected) ? entries[selected] : nil }

    func commit() {
        let target = selectedWindow
        dismiss()
        if let target { activate(target) }
    }

    private func shortcutModifierReleased() {
        guard releaseTimer != nil else { return }
        let hovered = panel.flatMap { item(at: $0.convertPoint(fromScreen: NSEvent.mouseLocation)) }
        let shouldCommit = confirmOnRelease || (selectedByHover && hovered == selected)
        cancelRelease()
        if shouldCommit { commit() }
    }

    private func cancelRelease() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        confirmOnRelease = false
        selectedByHover = false
    }

    private func preferredProject() -> Filter {
        var firstNonempty: UUID?
        for group in store.groups {
            let windows = store.projectWindows(in: group.id)
            guard !windows.isEmpty else { continue }
            if firstNonempty == nil { firstNonempty = group.id }
            if windows.contains(where: { store.windowNames[$0.key] != nil }) {
                return .project(group.id)
            }
        }
        return firstNonempty.map(Filter.project) ?? .all
    }

    private var filters: [Filter] {
        [.all] + store.groups.map { .project($0.id) } + [.unassigned]
    }

    private func title(for filter: Filter) -> String {
        switch filter {
        case .all: "Toutes les fenêtres"
        case let .project(id): store.groups.first { $0.id == id }?.name ?? "Projet"
        case .unassigned: "Sans projet"
        }
    }

    private func windows(for filter: Filter) -> [SpaceWindow] {
        switch filter {
        case .all: store.windows?.all ?? []
        case let .project(id): store.projectWindows(in: id)
        case .unassigned: store.projectWindows(in: nil)
        }
    }

    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedByHover = false
        lastPointerLocation = NSEvent.mouseLocation
        selected = (selected + delta + entries.count) % entries.count
        renderer?.selection = selected
    }

    private func cycleFilter(_ delta: Int) {
        let filters = self.filters
        let index = filters.firstIndex(of: filter) ?? 0
        filter = filters[(index + delta + filters.count) % filters.count]
        selected = 0
        _ = present(direction: delta)
    }

    private func present(direction: Int = 0) -> Bool {
        if !filters.contains(filter) { filter = .all }
        let query = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = windows(for: searching ? .all : filter)
        let labels = WindowNames.labels(for: candidates, customNames: store.windowNames)
        let windows = query.isEmpty ? candidates : candidates.filter {
            $0.label.localizedStandardContains(query) || labels[$0.key]?.localizedStandardContains(query) == true
        }
        entries = windows
        if let foreground {
            var frontWindows = windows.filter { $0.ownerPID == foreground.pid }
            if let index = frontWindows.firstIndex(where: { $0.id == foreground.windowID }) {
                let focused = frontWindows.remove(at: index)
                frontWindows.insert(focused, at: 0)
            }
            entries = frontWindows + windows.filter { $0.ownerPID != foreground.pid }
        }

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return false }
        let width = min(screen.visibleFrame.width - 24, 1500)
        let height = 226 + ProjectBadge.height + 12
        let canvas = CGRect(x: 32, y: 0, width: width - 64, height: 226)
        guard let renderer = GELayerRenderer.make(scale: screen.backingScaleFactor,
                                                   frame: CGRect(origin: .zero, size: canvas.size)) else {
            dismiss()
            report("Le calque du Dock de cette version de macOS est incompatible avec ProjectHop.")
            return false
        }

        if panel == nil { makePanel() }
        guard let panel, let host, let projectBadge, let emptyLabel, let searchField, let searchButton else { return false }
        panel.setFrame(CGRect(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2,
                              width: width, height: height).integral, display: false)
        host.frame = canvas
        host.layer = renderer.layer
        host.wantsLayer = true
        self.renderer = renderer
        var rendered: [(window: SpaceWindow, image: CGImage)] = []
        for entry in entries {
            let icon = NSRunningApplication(processIdentifier: entry.ownerPID)?.icon
                ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
                ?? NSWorkspace.shared.icon(for: .application)
            var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
            guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
            renderer.addIcon(image, title: labels[entry.key] ?? entry.label)
            rendered.append((entry, image))
        }
        entries = rendered.map(\.window)
        if !entries.isEmpty {
            renderer.layout()
            selected = min(selected, entries.count - 1)
            renderer.selection = selected
        }
        let material = entries.isEmpty ? CGRect.null : renderer.bezelFrame
        let bezel = material.isNull || material.isEmpty
            ? CGRect(x: canvas.midX - 132, y: canvas.midY - 23, width: 264, height: 46)
            : material.offsetBy(dx: canvas.minX, dy: canvas.minY)
        emptyLabel.isHidden = !entries.isEmpty
        emptyLabel.stringValue = searching ? "Aucun résultat" : "Aucune fenêtre dans ce projet"
        emptyLabel.frame = CGRect(x: bezel.minX, y: bezel.midY - 9, width: bezel.width, height: 18)
        if entries.isEmpty {
            let emptyFrame = bezel.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
            _ = renderer.setBezelFrame(emptyFrame, tileSize: 44)
            emptyLabel.textColor = .labelColor
        }

        projectBadge.isHidden = searching
        projectBadge.display(title: title(for: filter), above: bezel)
        searchButton.isHidden = searching
        searchButton.frame = CGRect(x: bezel.maxX + 7, y: bezel.midY - 17, width: 34, height: 34)
        searchField.isHidden = !searching
        searchField.frame = CGRect(x: canvas.midX - 145, y: canvas.maxY - 8, width: 290, height: 32)

        removeBadges.forEach { $0.button.removeFromSuperview() }
        removeBadges.removeAll()
        if !searching, case .project = filter {
            for (index, entry) in rendered.enumerated() {
                let icon = renderer.iconFrame(at: index, image: entry.image).offsetBy(dx: canvas.minX, dy: canvas.minY)
                guard !icon.isNull, !icon.isEmpty else { continue }
                let name = labels[entry.window.key] ?? entry.window.appName
                let button = makeButton(symbol: "minus", label: "Retirer \(name) du projet",
                                        action: #selector(removeFromProject(_:)))
                let size = min(20, max(12, icon.width * 0.28))
                button.frame = CGRect(x: icon.maxX - size * 0.75, y: icon.maxY - size * 0.75,
                                      width: size, height: size).integral
                button.layer?.cornerRadius = button.frame.height / 2
                button.tag = index
                button.isHidden = true
                panel.contentView?.addSubview(button)
                removeBadges.append(RemoveBadge(button: button, iconFrame: icon))
            }
        }

        if !panel.isVisible { panel.orderFrontRegardless() }
        if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
        updateRemoveBadges(at: panel.mouseLocationOutsideOfEventStream)
        if direction != 0 && !entries.isEmpty && PanelMotion.isEnabled {
            let offset = CGFloat(-direction) * 22
            PanelMotion.slide(on: renderer.layer, axis: .y, from: offset)
            for badge in removeBadges { PanelMotion.slide(on: badge.button.layer, axis: .y, from: offset) }
        }
        monitorEvents()
        return true
    }

    private func makePanel() {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.title = "ProjectHop — Sélecteur"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        let content = NSView()
        let host = NSView()
        let projectBadge = ProjectBadge(settingsTarget: self, settingsAction: #selector(openProjectSettings))
        let searchButton = makeButton(symbol: "magnifyingglass", label: "Chercher dans tous les espaces (⌘F)",
                                      action: #selector(openSearch))
        searchButton.layer?.cornerRadius = 17
        let searchField = NSSearchField()
        searchField.placeholderString = "Chercher dans tous les espaces"
        searchField.setAccessibilityLabel("Chercher dans tous les espaces")
        searchField.delegate = self
        let emptyLabel = NSTextField(labelWithString: "Aucune fenêtre dans ce projet")
        emptyLabel.alignment = .center
        emptyLabel.textColor = .white
        content.addSubview(host)
        content.addSubview(emptyLabel)
        content.addSubview(projectBadge)
        content.addSubview(searchButton)
        content.addSubview(searchField)
        panel.contentView = content
        self.panel = panel
        self.host = host
        self.projectBadge = projectBadge
        self.searchButton = searchButton
        self.searchField = searchField
        self.emptyLabel = emptyLabel
    }

    private func makeButton(symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: symbol == "minus" ? 10 : 15, weight: .semibold)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func openProjectSettings() {
        guard let panel, let host, let frame = renderer?.bezelFrame, !frame.isNull, !frame.isEmpty else {
            organize(nil)
            return
        }
        organize(panel.convertToScreen(host.convert(frame, to: nil)))
    }

    @objc private func openSearch() {
        guard !searching else { return }
        cancelRelease()
        searching = true
        selected = 0
        if present(), let searchField { panel?.makeFirstResponder(searchField) }
    }

    private func closeSearch() {
        panel?.makeFirstResponder(nil)
        searching = false
        searchField?.stringValue = ""
        selected = 0
        _ = present()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard searching else { return }
        selected = 0
        _ = present()
    }

    @objc private func removeFromProject(_ sender: NSButton) {
        guard case .project = filter, entries.indices.contains(sender.tag) else { return }
        let key = entries[sender.tag].key
        guard store.assignWindow(key, to: nil) else { return }
        _ = present()
    }

    func handleNavigation(_ action: ArrowAction) -> Bool {
        guard panel?.isVisible == true, panel?.isKeyWindow == true, !searching else { return false }
        navigate(action)
        return true
    }

    private func navigate(_ action: ArrowAction) {
        switch action {
        case let .window(direction):
            move(direction)
            if releaseTimer != nil { confirmOnRelease = true }
        case let .project(direction):
            confirmOnRelease = false
            selectedByHover = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible, !self.searching else { return }
                self.cycleFilter(direction)
            }
        }
    }

    private func resetScroll() {
        scrollDistance = .zero
        scrollHandled = false
    }

    func handleScroll(delta: CGPoint, phase: NSEvent.Phase, momentum: Bool) -> Bool {
        guard panel?.isVisible == true, panel?.isKeyWindow == true, !searching else { return false }
        if momentum { return true }

        if phase == .began || phase == .mayBegin { resetScroll() }
        if phase == .cancelled || phase == .ended {
            resetScroll()
            return true
        }
        let x = delta.x
        let y = delta.y
        if phase.isEmpty {
            guard abs(y) > abs(x) else { return false }
        } else {
            guard !scrollHandled else { return true }
            scrollDistance.x += x
            scrollDistance.y += y
            guard max(abs(scrollDistance.x), abs(scrollDistance.y)) >= 22 else { return true }
            scrollHandled = true
            guard abs(scrollDistance.y) > abs(scrollDistance.x) else { return true }
        }
        let vertical = phase.isEmpty ? y : scrollDistance.y
        navigate(.project(vertical > 0 ? -1 : 1))
        return true
    }

    private func item(at windowPoint: CGPoint) -> Int? {
        guard let host, let renderer else { return nil }
        let index = renderer.item(at: host.convert(windowPoint, from: nil))
        return entries.indices.contains(index) ? index : nil
    }

    private func monitorEvents() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .scrollWheel
            ]) { [weak self] event in
                let type = event.type
                let number = event.windowNumber
                let key = type == .keyDown ? Int(event.keyCode) : 0
                let flags = event.modifierFlags
                let point = event.locationInWindow
                let consumed: Bool
                if type == .scrollWheel {
                    let delta = CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
                    let phase = event.phase
                    let momentum = !event.momentumPhase.isEmpty
                    consumed = MainActor.assumeIsolated {
                        guard let self, number == self.panel?.windowNumber else { return false }
                        return self.handleScroll(delta: delta, phase: phase, momentum: momentum)
                    }
                } else {
                    consumed = MainActor.assumeIsolated {
                        self?.handle(type: type, windowNumber: number, key: key, flags: flags, point: point) == true
                    }
                }
                return consumed ? nil : event
            }
        }
        if outsideMonitor == nil {
            var events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
            if !WindowFocus.isTrusted { events.insert(.mouseMoved) }
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
                let isMovement = event.type == .mouseMoved
                MainActor.assumeIsolated {
                    if isMovement {
                        self?.updatePointer(at: NSEvent.mouseLocation)
                    } else {
                        self?.dismiss()
                    }
                }
            }
        }
    }

    func handlePointerMove(quartzPoint: CGPoint) {
        guard isVisible, let primary = NSScreen.screens.first else { return }
        updatePointer(at: CGPoint(x: quartzPoint.x, y: primary.frame.maxY - quartzPoint.y))
    }

    private func updateRemoveBadges(at point: CGPoint) {
        // Keep the badge visible while crossing from the icon to the button.
        let hovered = removeBadges.first {
            !$0.button.isHidden && $0.button.frame.contains(point)
        } ?? removeBadges.first {
            $0.iconFrame.contains(point)
        }
        for badge in removeBadges {
            let hidden = badge.button !== hovered?.button
            if badge.button.isHidden != hidden { badge.button.isHidden = hidden }
        }
    }

    private func overControl(_ point: CGPoint) -> Bool {
        if projectBadge?.contains(point) == true { return true }
        let controls: [NSControl?] = [searchButton, searchField]
        if controls.compactMap({ $0 }).contains(where: { !$0.isHidden && $0.frame.contains(point) }) {
            return true
        }
        return removeBadges.contains { !$0.button.isHidden && $0.button.frame.contains(point) }
    }

    private func updatePointer(at screenPoint: CGPoint) {
        guard let panel, panel.isVisible, screenPoint != lastPointerLocation else { return }
        lastPointerLocation = screenPoint
        let point = panel.convertPoint(fromScreen: screenPoint)
        updateRemoveBadges(at: point)
        guard !overControl(point), let index = item(at: point) else {
            selectedByHover = false
            return
        }
        if selected != index {
            selected = index
            renderer?.selection = index
        }
        selectedByHover = true
        confirmOnRelease = false
    }

    private func handle(type: NSEvent.EventType, windowNumber: Int, key: Int,
                        flags: NSEvent.ModifierFlags, point: CGPoint) -> Bool {
        if type == .mouseMoved {
            updatePointer(at: NSEvent.mouseLocation)
            return false
        }
        guard let panel, windowNumber == panel.windowNumber else { return false }
        switch type {
        case .flagsChanged:
            if !flags.contains(.option) { shortcutModifierReleased() }
        case .keyDown:
            if flags.intersection([.command, .option, .control]) == .command {
                if key == kVK_ANSI_F { openSearch(); return true }
                if key == kVK_ANSI_Comma { openProjectSettings(); return true }
            }
            if searching {
                switch key {
                case kVK_Escape: closeSearch()
                case kVK_Tab: move(flags.contains(.shift) ? -1 : 1)
                case kVK_UpArrow: move(-1)
                case kVK_DownArrow: move(1)
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    if selectedWindow != nil { commit() }
                default: return false
                }
                return true
            }
            if let action = ArrowAction(key) {
                navigate(action)
                return true
            }
            switch key {
            case kVK_Escape: dismiss()
            case kVK_Tab: navigate(.window(flags.contains(.shift) ? -1 : 1))
            case kVK_Return, kVK_ANSI_KeypadEnter: commit()
            default: return false
            }
            return true
        case .leftMouseDown:
            if overControl(point) {
                cancelRelease()
                return false
            }
            if let index = item(at: point) {
                selected = index
                commit()
                return true
            }
        default: break
        }
        return false
    }
}
