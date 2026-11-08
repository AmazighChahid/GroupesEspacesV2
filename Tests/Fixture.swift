import AppKit

@MainActor
final class FixtureApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let system = SpaceSystem()
    let output: URL
    private var windows: [NSWindow] = []
    private var originalSpace: DesktopSpace?

    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let marker = output.deletingLastPathComponent().appending(path: "fixture.pid")
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: marker, atomically: true, encoding: .utf8)
        Task { await prepare() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let path = output.deletingLastPathComponent().appending(path: "key-window.txt")
        try? String(window.windowNumber).write(to: path, atomically: true, encoding: .utf8)
    }

    func windowDidResignKey(_ notification: Notification) {
        let path = output.deletingLastPathComponent().appending(path: "key-window.txt")
        try? "".write(to: path, atomically: true, encoding: .utf8)
    }

    private func prepare() async {
        let spaces = system.readSpaces() ?? []
        let active = spaces.first(where: \.isActive)
        let desktops = spaces.filter { $0.kind == .desktop && $0.displayID == active?.displayID }
        guard let active, desktops.count >= 2 else {
            fail("Il faut deux bureaux sur le même écran.")
            return
        }

        originalSpace = active
        var targets: [CrossSpaceFixture.Target] = []
        for (index, desktop) in desktops.prefix(2).enumerated() {
            guard system.switchTo(desktop) else { fail("Changement de bureau refusé."); return }
            for _ in 0..<35 {
                if system.readSpaces()?.contains(where: { $0.id == desktop.id && $0.isActive }) == true { break }
                try? await Task.sleep(for: .milliseconds(70))
            }
            guard system.readSpaces()?.contains(where: { $0.id == desktop.id && $0.isActive }) == true else {
                fail("Bureau \(desktop.windowServerID) non actif.")
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            let name = index == 0 ? "Projet A" : "Projet B"
            let window = NSWindow(contentRect: NSRect(x: 180 + index * 80, y: 210, width: 520, height: 260),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Test V2 — \(name)"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.managed]
            window.delegate = self
            let label = NSTextField(labelWithString: window.title)
            label.font = .systemFont(ofSize: 28, weight: .semibold)
            label.frame = NSRect(x: 30, y: 110, width: 460, height: 40)
            window.contentView?.addSubview(label)
            windows.append(window)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(220))
            targets.append(.init(window: UInt32(window.windowNumber), space: desktop.id, name: name))
        }

        do {
            let fixture = CrossSpaceFixture(pid: ProcessInfo.processInfo.processIdentifier,
                                            originalSpace: active.id, targets: targets)
            try JSONEncoder().encode(fixture).write(to: output, options: .atomic)
            print("FIXTURE \(targets.map { $0.window })")
            fflush(nil)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        if let originalSpace { _ = system.switchTo(originalSpace) }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}

@main
struct FixtureMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureApp(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
