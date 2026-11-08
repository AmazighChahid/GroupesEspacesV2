import AppKit
import Carbon
import Darwin
import OSLog
import QuartzCore

struct DesktopSpace: Identifiable, Equatable {
    let windowServerID: UInt64
    let displayID: String
    let displayIndex: Int
    let uuid: String?
    let kind: Kind
    let name: String
    let bundleID: String?
    let isActive: Bool
    let fullScreenWindowIDs: Set<CGWindowID>

    enum Kind: String, Codable {
        case desktop
        case fullScreen
    }

    var id: String { "\(displayID):\(windowServerID)" }

    var reference: SpaceReference {
        let key: String
        if let uuid {
            key = "\(kind.rawValue):\(uuid)"
        } else if kind == .desktop {
            key = "default:\(displayID)"
        } else {
            key = "session:\(id)"
        }
        return SpaceReference(id: key, name: name, kind: kind, bundleID: bundleID)
    }
}

struct SpaceReference: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    let kind: DesktopSpace.Kind
    let bundleID: String?
}

@MainActor
final class SpaceSystem {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SetSpace = @convention(c) (Int32, CFString, UInt64) -> Void
    private typealias IsAnimating = @convention(c) (Int32, CFString) -> Bool
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private typealias FrontProcess = @convention(c) (UnsafePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32

    private enum ActivationMode: UInt32 {
        case appSwitcher = 0x100
        case userGenerated = 0x200
    }

    private let transitionLog = Logger(subsystem: "fr.groupesespaces.v2", category: "SpaceTransition")

    let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
    )
    private let coreGraphics = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY
    )
    private let hiServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices",
        RTLD_LAZY
    )

    private(set) lazy var connection: Int32? = {
        symbol("SLSMainConnectionID", in: skyLight, as: Connection.self)?()
    }()
    private lazy var copySpaces = symbol(
        "SLSCopyManagedDisplaySpaces", in: skyLight, as: CopySpaces.self
    )
    private lazy var setSpace = symbol(
        "CGSManagedDisplaySetCurrentSpace", in: coreGraphics, as: SetSpace.self
    )
    private lazy var isAnimating = symbol("SLSManagedDisplayIsAnimating", in: skyLight, as: IsAnimating.self)
    private lazy var processForPID = symbol("GetProcessForPID", in: hiServices, as: ProcessForPID.self)
    private lazy var frontProcess = symbol("_CPSSetFrontProcessWithOptions", in: coreGraphics, as: FrontProcess.self)

    func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    func readSpaces() -> [DesktopSpace]? {
        guard let connection, let copySpaces,
              let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        var desktopNumber = 0
        return displays.enumerated().flatMap { index, display -> [DesktopSpace] in
            guard let displayID = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else { return [] }
            let current = spaceID(in: display["Current Space"] as? [String: Any] ?? [:])

            return spaces.compactMap { row in
                guard let id = spaceID(in: row), let type = row["type"] as? Int else { return nil }
                let uuid = (row["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let kind: DesktopSpace.Kind
                let name: String
                let app: NSRunningApplication?
                switch type {
                case 0:
                    desktopNumber += 1
                    kind = .desktop
                    name = "Bureau \(desktopNumber)"
                    app = nil
                case 4:
                    kind = .fullScreen
                    app = (row["pid"] as? Int32).flatMap {
                        NSRunningApplication(processIdentifier: $0)
                    }
                    name = app?.localizedName ?? "Plein écran"
                default:
                    return nil
                }
                return DesktopSpace(
                    windowServerID: id, displayID: displayID, displayIndex: index + 1, uuid: uuid,
                    kind: kind, name: name, bundleID: app?.bundleIdentifier, isActive: id == current,
                    fullScreenWindowIDs: kind == .fullScreen ? fullScreenWindows(in: row) : []
                )
            }
        }
    }

    @discardableResult
    func switchTo(_ space: DesktopSpace) -> Bool {
        guard let connection, let setSpace,
              let current = readSpaces()?.first(where: { $0.id == space.id }) else { return false }
        if !current.isActive {
            setSpace(connection, current.displayID as CFString, current.windowServerID)
        }
        return true
    }

    func requestActivation(pid: pid_t, windowID: CGWindowID, usingAppSwitcherMode: Bool) -> Bool {
        guard !Task.isCancelled, let frontProcess, let processForPID else { return false }
        var process = ProcessSerialNumber()
        guard processForPID(pid, &process) == 0 else { return false }

        // The Dock uses process activation for ⌘ Tab. A window ID is needed when an app spans multiple Spaces.
        let mode: ActivationMode = usingAppSwitcherMode ? .appSwitcher : .userGenerated
        let target = usingAppSwitcherMode ? kCGNullWindowID : windowID
        return frontProcess(&process, target, mode.rawValue) == 0
    }

    func swipeTo(_ space: DesktopSpace) async -> Bool {
        if isCurrent(space) { return true }
        guard CGPreflightPostEventAccess() else {
            transitionLog.notice("Dock swipe unavailable: event posting is not authorized")
            return false
        }

        // The Dock routes swipes to the screen under the pointer.
        var displayBounds: CGRect?
        var cursorRestore: (original: CGPoint, parked: CGPoint)?
        defer {
            if let cursorRestore, CGEvent(source: nil)?.location == cursorRestore.parked {
                CGWarpMouseCursorPosition(cursorRestore.original)
            }
        }
        if NSScreen.screens.count > 1 {
            let displays = NSScreen.screens.compactMap {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            }
            let display = space.displayID == "Main" ? CGMainDisplayID() : displays.first { id in
                guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
                return (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(space.displayID) == .orderedSame
            }
            guard let display, let cursor = CGEvent(source: nil)?.location else { return false }
            let bounds = CGDisplayBounds(display)
            displayBounds = bounds
            if !bounds.contains(cursor) {
                let center = CGPoint(x: bounds.midX.rounded(.down), y: bounds.midY.rounded(.down))
                guard CGWarpMouseCursorPosition(center) == .success else { return false }
                cursorRestore = (cursor, center)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        // As in Spacewalk, recalculate the remaining distance before retrying.
        for _ in 0..<2 {
            guard !Task.isCancelled else { return false }
            if let displayBounds {
                guard let cursor = CGEvent(source: nil)?.location, displayBounds.contains(cursor) else { return false }
            }
            guard let spaces = readSpaces()?.filter({ $0.displayID == space.displayID }),
                  let from = spaces.firstIndex(where: \.isActive),
                  let to = spaces.firstIndex(where: { $0.id == space.id }) else { return false }
            let steps = abs(to - from)
            if steps == 0 { return true }
            transitionLog.notice("Dock swipe to Space \(space.windowServerID, privacy: .public), steps: \(steps, privacy: .public)")
            let postedAt = CACurrentMediaTime()
            guard DockSwipe.post(right: to > from, steps: steps) else { return false }
            // DockSwipe commits immediately. The Dock's reported Space is the completion signal.
            while !Task.isCancelled {
                if isCurrent(space) {
                    let elapsed = Int((CACurrentMediaTime() - postedAt) * 1000)
                    transitionLog.notice("Space \(space.windowServerID, privacy: .public) reached by Dock swipe in \(elapsed, privacy: .public) ms")
                    return true
                }
                guard CACurrentMediaTime() - postedAt < 0.6 else { break }
                try? await Task.sleep(for: .milliseconds(3))
            }
        }
        return false
    }

    func waitForSpaceTransition(to space: DesktopSpace) async -> Bool {
        guard let connection else { return false }
        let clock = ContinuousClock()
        let started = clock.now
        let display = space.displayID as CFString
        let grace: Duration = isAnimating == nil ? .milliseconds(500) : .milliseconds(120)
        var sawAnimation = false
        while !Task.isCancelled {
            let elapsed = clock.now - started
            let animating = isAnimating?(connection, display) == true
            sawAnimation = sawAnimation || animating
            if !animating, (sawAnimation || elapsed >= grace), isCurrent(space) {
                transitionLog.notice("Space \(space.windowServerID, privacy: .public) reached (animation: \(sawAnimation, privacy: .public))")
                return true
            }
            if elapsed >= .seconds(2) || (!sawAnimation && elapsed >= .milliseconds(650)) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func isCurrent(_ space: DesktopSpace) -> Bool {
        readSpaces()?.contains { $0.id == space.id && $0.isActive } == true
    }

    private func fullScreenWindows(in row: [String: Any]) -> Set<CGWindowID> {
        let layout = row["TileLayoutManager"] as? [String: Any]
        let tiles = layout?["TileSpaces"] as? [[String: Any]] ?? []
        var ids = Set(tiles.compactMap {
            ($0["TileWindowID"] as? NSNumber ?? $0["fs_wid"] as? NSNumber)?.uint32Value
        })
        if let owner = (row["fs_wid"] as? NSNumber)?.uint32Value { ids.insert(owner) }
        return ids.subtracting([kCGNullWindowID])
    }

    private func spaceID(in row: [String: Any]) -> UInt64? {
        (row["ManagedSpaceID"] as? NSNumber ?? row["id64"] as? NSNumber)?.uint64Value
    }
}
