import AppKit
import Carbon
import OSLog
import QuartzCore
import SwiftUI

@main
struct GroupesEspaces {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let verification = arguments.count == 2 && arguments[0] == "--verify-spaces"
            ? URL(fileURLWithPath: arguments[1]) : nil
        if verification == nil && arguments != ["--show-switcher"] && !arguments.isEmpty && !(arguments.count == 1 && arguments[0].hasPrefix("-psn_")) {
            do {
                try WindowCommand.run(arguments)
                return
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        let app = NSApplication.shared
        let delegate = GroupBarApp(verification: verification)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class GroupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class GroupBarApp: NSObject, NSApplicationDelegate {
    private let system = SpaceSystem()
    private let setupPreference = "firstLaunchSetup.v1"
    private let focusLog = Logger(subsystem: "fr.groupesespaces.v2", category: "WindowFocus")
    private let verification: URL?
    private let verificationDomain: String?
    private let preferences: UserDefaults
    private lazy var store = GroupStore(system: system, defaults: preferences)
    private lazy var nativeSwitcher = NativeSwitcher(store: store, activate: { [weak self] window in
        self?.openWindow(window)
    }, report: { [weak self] message in
        self?.store.message = message
        self?.showBar()
    }, organize: { [weak self] origin in
        self?.showProjectEditor(from: origin)
    })
    private var panel: GroupPanel?
    private var statusItem: NSStatusItem?
    private var hotkeyTap: CFMachPort?
    private var hotkeySource: CFRunLoopSource?
    private var setupPanel: GroupPanel?
    private var refreshTimer: Timer?
    private var morphTimer: Timer?
    private var editorRenderer: GELayerRenderer?
    private var outsideMonitor: Any?
    private var escapeMonitor: Any?
    private var switchTask: Task<Void, Never>?

    init(verification: URL?) {
        self.verification = verification
        if verification != nil {
            let domain = "fr.groupesespaces.v2.test.\(UUID().uuidString)"
            verificationDomain = domain
            preferences = UserDefaults(suiteName: domain)!
            preferences.set(true, forKey: "importedProjectSnapshot")
        } else {
            verificationDomain = nil
            preferences = .standard
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let verification {
            Task { await verifyCrossSpaceFixture(at: verification) }
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Groupes d’espaces V2")
            button.toolTip = "Groupes d’espaces V2"
        }
        statusItem = item
        registerHotkey()
        let menu = NSMenu()
        let organize = NSMenuItem(title: "Organiser les projets", action: #selector(toggleBar), keyEquivalent: "")
        organize.target = self
        menu.addItem(organize)
        let select = NSMenuItem(title: "Ouvrir le sélecteur", action: #selector(showNativeSwitcher), keyEquivalent: "")
        select.target = self
        menu.addItem(select)
        let accessibility = NSMenuItem(title: "Configurer l’Accessibilité…", action: #selector(authorizeWindows), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter Groupes d’espaces V2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        if !UserDefaults.standard.bool(forKey: setupPreference) || !WindowFocus.isTrusted {
            showSetup(openAccessibility: !WindowFocus.isTrusted)
        } else if ProcessInfo.processInfo.arguments.contains("--show-switcher") {
            showNativeSwitcher()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if setupPanel?.isVisible == true {
            setupPanel?.makeKeyAndOrderFront(nil)
        } else {
            showNativeSwitcher()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if verification == nil { registerHotkey() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hideBar()
        switchTask?.cancel()
        nativeSwitcher.dismiss()
        if let hotkeySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), hotkeySource, .commonModes) }
        if let hotkeyTap { CFMachPortInvalidate(hotkeyTap) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func toggleBar() {
        if setupPanel?.isVisible == true {
            setupPanel?.makeKeyAndOrderFront(nil)
        } else if panel?.isVisible == true {
            hideBar()
        } else {
            showProjectEditor()
        }
    }

    private func showProjectEditor(from origin: NativeSwitcher.MorphOrigin? = nil) {
        nativeSwitcher.dismiss()
        showBar(from: origin)
    }

    @objc private func showNativeSwitcher() {
        guard setupPanel?.isVisible != true else { return }
        hideBar()
        nativeSwitcher.show()
    }

    @objc private func authorizeWindows() {
        showSetup(openAccessibility: !WindowFocus.isTrusted)
    }

    private func handleShortcut(backwards: Bool) {
        guard setupPanel?.isVisible != true else { return }
        hideBar()
        nativeSwitcher.shortcut(backwards: backwards)
    }

    private func showSetup(openAccessibility: Bool = false) {
        nativeSwitcher.dismiss()
        if let setupPanel {
            NSApp.activate()
            setupPanel.makeKeyAndOrderFront(nil)
            if openAccessibility { WindowFocus.openSettings() }
            return
        }
        hideBar()
        let panel = GroupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 236),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        panel.title = "Configuration de Groupes d’espaces V2"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: SetupView(
            finish: { [weak self] in self?.finishSetup() },
            accessGranted: { [weak self] in self?.registerHotkey() }
        ))
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        panel.center()
        if let screen = panel.screen {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.minX + 24, y: frame.midY + panel.frame.height / 2))
        }
        setupPanel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if openAccessibility { WindowFocus.openSettings() }
    }

    private func finishSetup() {
        UserDefaults.standard.set(true, forKey: setupPreference)
        setupPanel?.close()
        setupPanel = nil
        registerHotkey()
        showNativeSwitcher()
    }

    @objc private func spaceDidChange() {
        store.refresh(includeWindows: panel?.isVisible == true)
    }

    private func showBar(from origin: NativeSwitcher.MorphOrigin? = nil) {
        store.refresh(includeWindows: true)
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let center = origin.map { CGPoint(x: $0.screenFrame.midX, y: $0.screenFrame.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(1060, visible.width - 32), height: min(620, visible.height - 32))
        let target = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                            width: size.width, height: size.height).integral
        let source = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : origin
        let windowFrame = source.map { target.union($0.screenFrame).integral } ?? target
        let panel = GroupPanel(contentRect: windowFrame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.title = "Organiser les projets — Groupes d’espaces V2"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let bounds = CGRect(origin: .zero, size: windowFrame.size)
        let content = NSView(frame: bounds)
        let backdrop = NSView(frame: bounds)
        backdrop.wantsLayer = true
        content.addSubview(backdrop)

        let editorFrame = target.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        let initialFrame = source?.screenFrame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY) ?? editorFrame
        let tileSize = source?.tileSize ?? 128
        let renderer = GELayerRenderer.make(scale: screen.backingScaleFactor, frame: bounds)
        let hasMaterial = renderer?.setBezelFrame(initialFrame, tileSize: tileSize) == true
        if hasMaterial, let renderer {
            editorRenderer = renderer
            backdrop.layer?.addSublayer(renderer.layer)
        }

        let host = NSHostingView(rootView: GroupBar(
            store: store,
            openSpace: { [weak self] in self?.openSpace($0) },
            openWindow: { [weak self] in self?.openWindow($0) },
            close: { [weak self] in self?.hideBar() },
            openSetup: { [weak self] in self?.authorizeWindows() },
            nativeBackground: hasMaterial
        ))
        host.sizingOptions = []
        host.frame = editorFrame
        content.addSubview(host)
        panel.contentView = content
        self.panel = panel

        if source != nil && hasMaterial {
            host.alphaValue = 0
        } else if windowFrame != target {
            panel.setFrame(target, display: false)
            host.frame = CGRect(origin: .zero, size: target.size)
        }
        panel.makeKeyAndOrderFront(nil)

        if let source, hasMaterial {
            let started = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak panel, weak host, weak backdrop] timer in
                let finished = MainActor.assumeIsolated {
                    guard let self, let renderer = self.editorRenderer, let panel, let host, let backdrop else {
                        return true
                    }
                    let progress = min(1, (CACurrentMediaTime() - started) / 0.27)
                    let eased = 1 - pow(1 - progress, 3)
                    let frame = CGRect(
                        x: initialFrame.minX + (editorFrame.minX - initialFrame.minX) * eased,
                        y: initialFrame.minY + (editorFrame.minY - initialFrame.minY) * eased,
                        width: initialFrame.width + (editorFrame.width - initialFrame.width) * eased,
                        height: initialFrame.height + (editorFrame.height - initialFrame.height) * eased
                    )
                    let size = UInt32((Double(source.tileSize) + (128 - Double(source.tileSize)) * eased).rounded())
                    _ = renderer.setBezelFrame(frame, tileSize: size)
                    host.alphaValue = max(0, (progress - 0.42) / 0.58)
                    if progress == 1 {
                        self.morphTimer = nil
                        if windowFrame != target {
                            let finalBounds = CGRect(origin: .zero, size: target.size)
                            panel.setFrame(target, display: false)
                            backdrop.frame = finalBounds
                            host.frame = finalBounds
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            renderer.layer.frame = finalBounds
                            _ = renderer.setBezelFrame(finalBounds, tileSize: 128)
                            CATransaction.commit()
                        }
                    }
                    return progress == 1
                }
                if finished { timer.invalidate() }
            }
            morphTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hideBar()
            }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let number = event.windowNumber
            let key = Int(event.keyCode)
            let handled = MainActor.assumeIsolated {
                guard let self, number == self.panel?.windowNumber, key == kVK_Escape else { return false }
                self.hideBar()
                return true
            }
            return handled ? nil : event
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh(includeWindows: true) }
        }
    }

    private func hideBar() {
        panel?.orderOut(nil)
        panel = nil
        morphTimer?.invalidate()
        morphTimer = nil
        editorRenderer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideMonitor = nil
        escapeMonitor = nil
    }

    private func openSpace(_ space: DesktopSpace) {
        beginSelection {
            if await self.visit(space) {
                self.store.refresh()
            } else if !Task.isCancelled {
                self.store.message = "Impossible d’ouvrir \(space.name)."
                self.showBar()
            }
        }
    }

    private func openWindow(_ selected: SpaceWindow) {
        store.refresh(includeWindows: true)
        guard let window = store.windows?.all.first(where: { $0.key == selected.key }) else {
            store.message = "Cette fenêtre a été fermée."
            return
        }
        let space = store.location(for: window)
        let singleWindowApplication = store.windows?.all.contains {
            $0.ownerPID == window.ownerPID && $0.id != window.id
        } == false
        beginSelection {
            guard let application = NSRunningApplication(processIdentifier: window.ownerPID) else { return }
            if application.isHidden { application.unhide() }
            if let space, !self.system.isCurrent(space) {
                let changesApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier != window.ownerPID
                let usingAppSwitcherMode = singleWindowApplication && changesApplication
                var reachedSpace = false
                if WindowFocus.isTrusted, !window.isMinimized {
                    var requested = changesApplication && self.system.requestActivation(
                        pid: window.ownerPID, windowID: window.id, usingAppSwitcherMode: usingAppSwitcherMode
                    )
                    if !usingAppSwitcherMode {
                        let result = await WindowFocus.raiseForSpaceTransition(pid: window.ownerPID, id: window.id)
                        guard !Task.isCancelled else { return }
                        self.focusLog.notice("AXRaise before switching to space \(space.windowServerID, privacy: .public), window \(window.id, privacy: .public): \(result.rawValue, privacy: .public)")
                        requested = requested || result == .success
                    }
                    if requested {
                        reachedSpace = await self.system.waitForSpaceTransition(to: space)
                    }
                }
                guard !Task.isCancelled else { return }
                if !reachedSpace {
                    self.focusLog.notice("Direct fallback to space \(space.windowServerID, privacy: .public), window \(window.id, privacy: .public)")
                }
                if !reachedSpace, !(await self.visit(space)) {
                    if !Task.isCancelled {
                        self.store.message = "Impossible d’ouvrir \(space.name)."
                        self.showBar()
                    }
                    return
                }
            }
            guard !Task.isCancelled else { return }
            if !self.isForeground(application) {
                NSApp.yieldActivation(to: application)
                _ = application.activate(from: .current)
            }
            var result = WindowFocus.Result.missingWindow
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                if WindowFocus.isTrusted {
                    result = await Task.detached(priority: .userInitiated) {
                        WindowFocus.raise(pid: window.ownerPID, id: window.id, minimized: window.isMinimized)
                    }.value
                } else {
                    // AppKit can already select the right window when the app is brought forward on its Space.
                    result = WindowFocus.frontVisibleWindowID(pid: window.ownerPID) == window.id
                        ? .focused : .notAuthorized
                }
                guard !Task.isCancelled else { return }
                let rightApplication = self.isForeground(application)
                let rightSpace = space.map(self.system.isCurrent) ?? true
                if result == .focused && rightApplication && rightSpace
                    && WindowFocus.isWindowVisible(pid: window.ownerPID, id: window.id) {
                    self.focusLog.notice("window \(window.id, privacy: .public) focused")
                    self.store.refresh()
                    return
                }
                if result == .focused { result = rightApplication ? .differentWindow : .applicationNotActive }
                if let space, !rightSpace, !(await self.visit(space)) { break }
                guard !Task.isCancelled else { return }
                if !rightApplication {
                    _ = application.activate(from: .current)
                }
            }
            self.focusLog.notice("window \(window.id, privacy: .public) \(result.rawValue, privacy: .public)")
            self.store.message = result.description
            self.showBar()
            if result == .notAuthorized && self.verification == nil { WindowFocus.requestAccess() }
        }
    }

    private func isForeground(_ application: NSRunningApplication) -> Bool {
        let workspace = NSWorkspace.shared
        let pid = application.processIdentifier
        return workspace.frontmostApplication?.processIdentifier == pid
            && (application.activationPolicy != .regular || workspace.menuBarOwningApplication?.processIdentifier == pid)
    }

    private func beginSelection(_ action: @escaping @MainActor () async -> Void) {
        switchTask?.cancel()
        hideBar()
        store.message = nil
        switchTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    private func visit(_ space: DesktopSpace) async -> Bool {
        guard !Task.isCancelled, system.switchTo(space) else { return false }
        for _ in 0..<12 {
            guard !Task.isCancelled else { return false }
            if system.isCurrent(space) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return false
    }

    private func verifyCrossSpaceFixture(at url: URL) async {
        var originalSpace: String?
        var status: Int32 = 0
        defer {
            nativeSwitcher.dismiss()
            hideBar()
            if let originalSpace, let space = system.readSpaces()?.first(where: { $0.id == originalSpace }) {
                _ = system.switchTo(space)
            }
            if let verificationDomain { preferences.removePersistentDomain(forName: verificationDomain) }
            fflush(nil)
            exit(status)
        }
        do {
            let fixture = try JSONDecoder().decode(CrossSpaceFixture.self, from: Data(contentsOf: url))
            originalSpace = fixture.originalSpace
            print("Mode Accessibilité : \(WindowFocus.isTrusted ? "autorisé" : "vérification WindowServer")")
            guard fixture.targets.count == 2, fixture.targets[0].space != fixture.targets[1].space else {
                throw VerificationError(message: "Deux Spaces distincts sont requis.")
            }

            store.refresh(includeWindows: true)
            var groups: [UUID] = []
            for target in fixture.targets {
                let owner = target.ownerPID ?? fixture.pid
                guard let window = store.windows?.all.first(where: { $0.id == target.window && $0.ownerPID == owner }),
                      store.location(for: window)?.id == target.space else {
                    throw VerificationError(message: "La fenêtre \(target.window) ne se trouve pas sur le Space attendu.")
                }
                let group = store.addGroup()
                store.renameGroup(group, to: target.name)
                guard store.assignWindow(window.key, to: group) else {
                    throw VerificationError(message: "Affectation au projet impossible.")
                }
                groups.append(group)
            }

            let keyboardTest = WindowFocus.isTrusted && CGPreflightPostEventAccess()
                && NSRunningApplication.runningApplications(withBundleIdentifier: "fr.groupesespaces.v2").count == 1
            if keyboardTest {
                registerHotkey()
                Self.postTestKey(kVK_Tab, flags: .maskAlternate)
                for _ in 0..<12 {
                    if nativeSwitcher.isVisible { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard nativeSwitcher.isVisible else {
                    throw VerificationError(message: "⌥ Tab n’a pas ouvert le sélecteur.")
                }
                print("⌥ Tab reçu · sélecteur ouvert")
                nativeSwitcher.dismiss()
            }
            for index in [0, 1, 0] {
                let target = fixture.targets[index]
                let initial = keyboardTest ? 1 - index : index
                guard nativeSwitcher.show(filter: .project(groups[initial])) else {
                    throw VerificationError(message: "Le sélecteur n’a pas pu s’ouvrir.")
                }
                if keyboardTest {
                    if index == 0 {
                        Self.postTestKey(kVK_UpArrow, flags: [])
                    } else {
                        Self.postTestKey(kVK_PageDown, flags: .maskSecondaryFn)
                    }
                    for _ in 0..<12 {
                        if nativeSwitcher.selectedWindow?.id == target.window { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                guard nativeSwitcher.selectedWindow?.id == target.window else {
                    throw VerificationError(message: "Le filtre \(target.name) ne sélectionne pas la bonne fenêtre.")
                }
                if keyboardTest { print("Carrousel clavier · \(target.name)") }
                nativeSwitcher.commit()
                await switchTask?.value
                let owner = target.ownerPID ?? fixture.pid
                let focusFile = url.deletingLastPathComponent().appending(path: "key-window.txt")
                var observed = ""
                var matchedSpace: DesktopSpace?
                for _ in 0..<20 {
                    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let menuPID = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
                    let reportedKey = (try? String(contentsOf: focusFile, encoding: .utf8)).flatMap(UInt32.init)
                    let focused = WindowFocus.isTrusted ? WindowFocus.focusedWindowID(pid: owner) : reportedKey
                    let activeSpace = system.readSpaces()?.first(where: { $0.id == target.space && $0.isActive })
                    let visible = activeSpace?.kind == .fullScreen
                        ? WindowFocus.isWindowVisible(pid: owner, id: target.window)
                        : WindowFocus.frontVisibleWindowID(pid: owner) == target.window
                    if frontPID == owner, menuPID == owner, focused == target.window, visible, let activeSpace {
                        matchedSpace = activeSpace
                        break
                    }
                    observed = "PID \(String(describing: frontPID)), menu \(String(describing: menuPID)), fenêtre active \(String(describing: focused)), visible \(visible), Space actif \(activeSpace != nil)"
                    try? await Task.sleep(for: .milliseconds(60))
                }
                guard let matchedSpace else {
                    throw VerificationError(message: "Attendu fenêtre \(target.window) sur \(target.space), obtenu \(observed).")
                }
                print("PASS \(target.name) · PID \(owner) · fenêtre \(target.window) · Space \(matchedSpace.windowServerID) · menu \(owner)")
            }
        } catch {
            print("ÉCHEC \(error)")
            status = 1
        }
    }

    private struct VerificationError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func postTestKey(_ key: Int, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private func registerHotkey() {
        guard hotkeyTap == nil, WindowFocus.isTrusted else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                 | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                 | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
                 | (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<GroupBarApp>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated {
                        if let tap = app.hotkeyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    }
                    return Unmanaged.passUnretained(event)
                }

                if type == .mouseMoved {
                    let point = event.location
                    MainActor.assumeIsolated { app.nativeSwitcher.handlePointerMove(quartzPoint: point) }
                    return Unmanaged.passUnretained(event)
                }

                if type == .scrollWheel {
                    guard let scroll = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
                    let delta = CGPoint(x: scroll.scrollingDeltaX, y: scroll.scrollingDeltaY)
                    let phase = scroll.phase
                    let momentum = !scroll.momentumPhase.isEmpty
                    let handled = MainActor.assumeIsolated {
                        app.nativeSwitcher.handleScroll(delta: delta, phase: phase, momentum: momentum)
                    }
                    return handled ? nil : Unmanaged.passUnretained(event)
                }

                let flags = event.flags
                guard flags.intersection([.maskCommand, .maskControl]).isEmpty else {
                    return Unmanaged.passUnretained(event)
                }
                let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if key == kVK_Tab && flags.contains(.maskAlternate) {
                    let configuring = MainActor.assumeIsolated { app.setupPanel?.isVisible == true }
                    guard !configuring else { return Unmanaged.passUnretained(event) }
                    if type == .keyDown {
                        let backwards = flags.contains(.maskShift)
                        DispatchQueue.main.async { app.handleShortcut(backwards: backwards) }
                    }
                    return nil
                }
                if type == .keyDown {
                    let handled = MainActor.assumeIsolated {
                        guard let action = NativeSwitcher.ArrowAction(key) else { return false }
                        return app.nativeSwitcher.handleNavigation(action)
                    }
                    if handled { return nil }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            store.message = "Le raccourci ⌥ Tab est indisponible. Ouvre le sélecteur depuis la barre des menus."
            focusLog.notice("Option+Tab indisponible")
            return
        }
        hotkeyTap = tap
        hotkeySource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        focusLog.notice("Option+Tab actif")
    }
}
