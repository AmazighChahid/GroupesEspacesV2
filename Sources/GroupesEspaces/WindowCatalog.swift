import AppKit

struct SpaceWindow: Equatable, Identifiable, Sendable {
    let id: CGWindowID
    let key: String
    let ownerPID: pid_t
    let appName: String
    let title: String?
    let isMinimized: Bool

    var label: String {
        title.map { "\(appName) · \($0)" } ?? appName
    }
}

struct WindowCatalog: Equatable {
    var bySpace: [DesktopSpace.ID: [SpaceWindow]] = [:]
    var unplaced: [SpaceWindow] = []

    var all: [SpaceWindow] {
        var seen = Set<CGWindowID>()
        return (bySpace.values.flatMap { $0 } + unplaced)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }

    var count: Int { all.count }
}

@MainActor
final class WindowInventory {
    private typealias Membership = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias Query = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias Iterator = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Advance = @convention(c) (CFTypeRef) -> Bool
    private typealias GetWindowID = @convention(c) (CFTypeRef) -> CGWindowID
    private typealias GetFlags = @convention(c) (CFTypeRef) -> UInt64

    private struct WindowState {
        let parent: CGWindowID
        let attributes: UInt64
        let tags: UInt64

        // WindowServer tags distinguish minimized and app-hidden windows from ordered-out surfaces.
        var isOrderedIn: Bool { attributes & 0x2 != 0 }
        var isMinimized: Bool { tags & (1 << 60) != 0 }
        var isAppHidden: Bool { tags & (1 << 39) != 0 }
    }

    private struct Candidate {
        let id: CGWindowID
        let pid: pid_t
        let app: NSRunningApplication?
        let ownerName: String
        let title: String?
        let isOnScreen: Bool
    }

    private let system: SpaceSystem
    private lazy var copyMembership = system.symbol(
        "SLSCopySpacesForWindows", in: system.skyLight, as: Membership.self
    )
    private lazy var query = system.symbol(
        "SLSWindowQueryWindows", in: system.skyLight, as: Query.self
    )
    private lazy var makeIterator = system.symbol(
        "SLSWindowQueryResultCopyWindows", in: system.skyLight, as: Iterator.self
    )
    private lazy var advance = system.symbol("SLSWindowIteratorAdvance", in: system.skyLight, as: Advance.self)
    private lazy var windowID = system.symbol("SLSWindowIteratorGetWindowID", in: system.skyLight, as: GetWindowID.self)
    private lazy var parentID = system.symbol("SLSWindowIteratorGetParentID", in: system.skyLight, as: GetWindowID.self)
    private lazy var attributes = system.symbol("SLSWindowIteratorGetAttributes", in: system.skyLight, as: GetFlags.self)
    private lazy var tags = system.symbol("SLSWindowIteratorGetTags", in: system.skyLight, as: GetFlags.self)

    init(system: SpaceSystem) {
        self.system = system
    }

    func read(in spaces: [DesktopSpace]) -> WindowCatalog? {
        guard let connection = system.connection, let copyMembership,
              let rows = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return nil }

        let fullScreenSpaces = Dictionary(
            spaces.flatMap { space in space.fullScreenWindowIDs.map { ($0, space) } },
            uniquingKeysWith: { first, _ in first }
        )
        let spacesByID = Dictionary(grouping: spaces, by: \.windowServerID)
        let apps = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates: [Candidate] = rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? CGWindowID,
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { return nil }
            let app = apps[pid] ?? NSRunningApplication(processIdentifier: pid)
            guard app?.bundleIdentifier != "fr.groupesespaces.v2" else { return nil }
            if fullScreenSpaces[id] == nil {
                guard let app, app.activationPolicy != .prohibited,
                      row[kCGWindowLayer as String] as? Int == 0,
                      let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                      frame.width > 1, frame.height > 1,
                      (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            }
            let title = (row[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Candidate(
                id: id, pid: pid, app: app, ownerName: row[kCGWindowOwnerName as String] as? String ?? "Fenêtre",
                title: title?.isEmpty == false ? title : nil,
                isOnScreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false
            )
        }

        let states = readStates(candidates.map(\.id), connection: connection)
        var catalog = WindowCatalog()
        for candidate in candidates {
            let appName = candidate.app?.localizedName ?? candidate.ownerName
            let state = states[candidate.id]
            let launched = candidate.app?.launchDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            let window = SpaceWindow(
                id: candidate.id, key: "\(candidate.pid)-\(launched)-\(candidate.id)", ownerPID: candidate.pid,
                appName: appName, title: candidate.title == appName ? nil : candidate.title,
                isMinimized: state?.isMinimized == true
            )
            if let fullScreen = fullScreenSpaces[candidate.id] {
                catalog.bySpace[fullScreen.id, default: []].append(window)
                continue
            }
            guard (state?.parent ?? kCGNullWindowID) == kCGNullWindowID else { continue }
            let retained = copyMembership(connection, 0x7, [NSNumber(value: candidate.id)] as CFArray)
            let membership = retained?.takeRetainedValue() as? [NSNumber] ?? []
            let matchingSpaces: [DesktopSpace] = membership.flatMap { spacesByID[$0.uint64Value] ?? [] }
            let bundleID = candidate.app?.bundleIdentifier
            let destinations = matchingSpaces.filter { space in
                if space.kind == .desktop { return true }
                return space.fullScreenWindowIDs.isEmpty && bundleID != nil && space.bundleID == bundleID
            }
            let isOpen = candidate.isOnScreen || state?.isOrderedIn == true
                || state?.isMinimized == true || state?.isAppHidden == true
                || candidate.app?.isHidden == true
                || (state == nil && !destinations.isEmpty)
            guard isOpen else { continue }

            if destinations.isEmpty {
                // Minimized windows can outlive their reported desktop membership.
                if window.isMinimized || membership.isEmpty && candidate.isOnScreen {
                    catalog.unplaced.append(window)
                }
            } else {
                for space in destinations {
                    catalog.bySpace[space.id, default: []].append(window)
                }
            }
        }

        for id in catalog.bySpace.keys {
            catalog.bySpace[id]?.sort(by: windowOrder)
        }
        catalog.unplaced.sort(by: windowOrder)
        return catalog
    }

    private func readStates(_ ids: [CGWindowID], connection: Int32) -> [CGWindowID: WindowState] {
        guard !ids.isEmpty, let query, let makeIterator, let advance,
              let windowID, let parentID, let attributes, let tags,
              let snapshot = query(connection, ids.map { NSNumber(value: $0) } as CFArray, 0)?
                .takeRetainedValue(),
              let iterator = makeIterator(snapshot)?.takeRetainedValue() else { return [:] }

        var states: [CGWindowID: WindowState] = [:]
        while advance(iterator) {
            states[windowID(iterator)] = WindowState(
                parent: parentID(iterator), attributes: attributes(iterator), tags: tags(iterator)
            )
        }
        return states
    }

    private func windowOrder(_ first: SpaceWindow, _ second: SpaceWindow) -> Bool {
        let order = first.label.localizedStandardCompare(second.label)
        return order == .orderedSame ? first.id < second.id : order == .orderedAscending
    }
}
