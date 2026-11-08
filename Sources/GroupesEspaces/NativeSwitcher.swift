import AppKit
import Carbon
import CoreGraphics
import QuartzCore
import UniformTypeIdentifiers

@MainActor
final class NativeSwitcher {
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

    private let store: GroupStore
    private let activate: (SpaceWindow) -> Void
    private let report: (String) -> Void
    private let organize: () -> Void
    private var panel: Panel?
    private var host: NSView?
    private var carousel: ProjectCarousel?
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

    init(store: GroupStore, activate: @escaping (SpaceWindow) -> Void,
         report: @escaping (String) -> Void, organize: @escaping () -> Void) {
        self.store = store
        self.activate = activate
        self.report = report
        self.organize = organize
    }

    func shortcut(backwards: Bool) {
        if panel?.isVisible == true {
            move(backwards ? -1 : 1)
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
                guard !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) else { return }
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
        let windowID = WindowFocus.focusedWindowID(pid: pid) ?? WindowFocus.frontVisibleWindowID(pid: pid)
        let focused = appWindows.first { $0.id == windowID }
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
        let windows = windows(for: filter)
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
        let width = min(screen.frame.width - 48, 1440)
        let height = 226 + ProjectCarousel.height + 3
        let canvas = CGRect(x: 0, y: 0, width: width, height: 226)
        guard let renderer = GELayerRenderer.make(scale: screen.backingScaleFactor, frame: canvas) else {
            dismiss()
            report("Le calque du Dock de cette version de macOS est incompatible avec la V2.")
            return false
        }

        if panel == nil { makePanel() }
        guard let panel, let host, let carousel, let emptyLabel else { return false }
        panel.setFrame(CGRect(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2,
                              width: width, height: height).integral, display: false)
        host.frame = canvas
        host.layer = renderer.layer
        host.wantsLayer = true
        self.renderer = renderer
        let labels = WindowNames.labels(for: entries, customNames: store.windowNames)
        var rendered: [SpaceWindow] = []
        for entry in entries {
            let icon = NSRunningApplication(processIdentifier: entry.ownerPID)?.icon
                ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
                ?? NSWorkspace.shared.icon(for: .application)
            var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
            guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
            renderer.addIcon(image, title: labels[entry.key] ?? entry.label)
            rendered.append(entry)
        }
        entries = rendered
        if !entries.isEmpty {
            renderer.layout()
            selected = min(selected, entries.count - 1)
            renderer.selection = selected
        }
        emptyLabel.isHidden = !entries.isEmpty
        emptyLabel.frame = CGRect(x: 0, y: canvas.midY - 10, width: width, height: 22)

        let filters = self.filters
        let carouselWidth: CGFloat = 304
        carousel.frame = CGRect(x: (width - carouselWidth) / 2, y: height - ProjectCarousel.height,
                                width: carouselWidth, height: ProjectCarousel.height)
        carousel.display(titles: filters.map(title(for:)), selected: filters.firstIndex(of: filter) ?? 0,
                         count: entries.count, direction: direction)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        if direction != 0 && !entries.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = CGFloat(-direction) * 22
            slide.toValue = 0
            slide.duration = 0.19
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            renderer.layer.add(slide, forKey: "projectSlide")
        }
        monitorEvents()
        return true
    }

    private func makePanel() {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.title = "Groupes d’espaces V2 — Sélecteur"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        let content = NSView()
        let host = NSView()
        let carousel = ProjectCarousel(settingsTarget: self, settingsAction: #selector(openProjectSettings))
        let emptyLabel = NSTextField(labelWithString: "Aucune fenêtre dans ce projet")
        emptyLabel.alignment = .center
        emptyLabel.textColor = .white
        content.addSubview(host)
        content.addSubview(emptyLabel)
        content.addSubview(carousel)
        panel.contentView = content
        self.panel = panel
        self.host = host
        self.carousel = carousel
        self.emptyLabel = emptyLabel
    }

    @objc private func openProjectSettings() {
        organize()
    }

    func handleNavigation(_ action: ArrowAction) -> Bool {
        guard panel?.isVisible == true, panel?.isKeyWindow == true else { return false }
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
                guard let self, self.isVisible else { return }
                self.cycleFilter(direction)
            }
        }
    }

    private func item(at windowPoint: CGPoint) -> Int? {
        guard let host, let renderer else { return nil }
        let index = renderer.item(at: host.convert(windowPoint, from: nil))
        return entries.indices.contains(index) ? index : nil
    }

    private func monitorEvents() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown]) { [weak self] event in
                let type = event.type
                let number = event.windowNumber
                let key = type == .keyDown ? Int(event.keyCode) : 0
                let flags = event.modifierFlags
                let location = event.locationInWindow
                let consumed = MainActor.assumeIsolated {
                    self?.handle(type: type, windowNumber: number, key: key, flags: flags, location: location) == true
                }
                return consumed ? nil : event
            }
        }
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    private func handle(type: NSEvent.EventType, windowNumber: Int, key: Int,
                        flags: NSEvent.ModifierFlags, location: CGPoint) -> Bool {
        guard let panel, windowNumber == panel.windowNumber else { return false }
        switch type {
        case .flagsChanged:
            if !flags.contains(.function) { shortcutModifierReleased() }
        case .keyDown:
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
        case .mouseMoved, .leftMouseDown:
            if carousel?.isOverSettings(location) == true {
                if type == .leftMouseDown { cancelRelease() }
                return false
            }
            if let index = item(at: location) {
                selected = index
                renderer?.selection = index
                if type == .leftMouseDown {
                    commit()
                } else {
                    selectedByHover = true
                    confirmOnRelease = false
                }
                return true
            }
        default: break
        }
        return false
    }
}
