import AppKit
import OSLog
import SwiftUI

struct SpaceGroup: Codable, Identifiable {
    var id = UUID()
    var name: String
    var members: [SpaceReference] = []
    var lastVisited: String?
}

@MainActor
final class GroupStore: ObservableObject {
    enum NamingStatus {
        case requesting(windowCount: Int, startedAt: Date)
        case finished(String, startedAt: Date? = nil)

        var isActive: Bool {
            switch self {
            case .requesting: true
            case .finished: false
            }
        }

        var startedAt: Date? {
            switch self {
            case let .requesting(_, date): date
            case let .finished(_, date): date
            }
        }

        var text: String {
            switch self {
            case let .requesting(count, _): "Nommage de \(count) fenêtre\(count == 1 ? "" : "s")…"
            case let .finished(message, _): message
            }
        }
    }

    @Published private(set) var groups: [SpaceGroup]
    @Published private(set) var spaces: [DesktopSpace] = []
    @Published private(set) var windows: WindowCatalog?
    @Published private(set) var windowNames: [String: String] = [:]
    @Published private(set) var namingStatus: NamingStatus? {
        didSet { message = namingStatus?.text }
    }
    @Published private(set) var windowGroups: [String: String]
    @Published private var windowOrder: [String: [String]]
    @Published var message: String?
    var isNaming: Bool { namingStatus?.isActive == true }

    private let system: SpaceSystem
    private let inventory: WindowInventory
    private let defaults: UserDefaults
    private let namingLog = Logger(subsystem: "fr.groupesespaces.v2", category: "WindowNaming")
    private var seenWindowIDs: Set<CGWindowID>?
    private var pendingWindowIDs: Set<CGWindowID> = []
    private var automaticNamingTask: Task<Void, Never>?
    private let storageKey = "spaceGroups.v1"
    private let windowGroupKey = "windowGroups.v1"
    private let windowOrderKey = "windowOrder.v1"

    init(system: SpaceSystem, defaults: UserDefaults = .standard, importSideDock: Bool = true) {
        self.system = system
        inventory = WindowInventory(system: system)
        self.defaults = defaults
        if defaults.object(forKey: "importedProjectSnapshot") == nil {
            let original = defaults.persistentDomain(forName: "fr.groupesespaces.local") ?? [:]
            for key in [storageKey, windowGroupKey, windowOrderKey] where defaults.object(forKey: key) == nil {
                if let value = original[key] { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "importedProjectSnapshot")
        }
        let saved = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([SpaceGroup].self, from: $0)
        }
        groups = saved ?? []
        windowGroups = defaults.dictionary(forKey: windowGroupKey) as? [String: String] ?? [:]
        windowOrder = defaults.dictionary(forKey: windowOrderKey) as? [String: [String]] ?? [:]
        if importSideDock { mergeSideDockSnapshot() }
        refresh()
    }

    func refresh(includeWindows: Bool = false) {
        guard let current = system.readSpaces(), !current.isEmpty else {
            spaces = []
            windows = nil
            message = "macOS ne renvoie aucun espace pour le moment."
            return
        }
        if message == "macOS ne renvoie aucun espace pour le moment." { message = nil }
        if spaces != current { spaces = current }
        if includeWindows {
            let catalog = inventory.read(in: current)
            if windows != catalog { windows = catalog }
            let names = WindowNames.read(for: catalog?.all ?? [])
            if windowNames != names { windowNames = names }
        }
        var updated = groups
        for index in updated.indices {
            for memberIndex in updated[index].members.indices {
                let member = updated[index].members[memberIndex]
                guard let live = liveSpace(for: member) else { continue }
                if live.reference != member {
                    updated[index].members[memberIndex] = live.reference
                    if updated[index].lastVisited == member.id {
                        updated[index].lastVisited = live.reference.id
                    }
                }
                if live.isActive { updated[index].lastVisited = live.reference.id }
            }
        }
        if !zip(groups, updated).allSatisfy({
            $0.members == $1.members && $0.lastVisited == $1.lastVisited
        }) {
            groups = updated
            save()
        }
    }

    func liveSpace(for member: SpaceReference) -> DesktopSpace? {
        if let exact = spaces.first(where: { $0.reference.id == member.id }) { return exact }
        guard member.kind == .fullScreen, let app = member.bundleID else { return nil }
        let claimed = groups.flatMap(\.members).filter { $0.bundleID == app }
        let candidates = spaces.filter { $0.kind == .fullScreen && $0.bundleID == app }
        return claimed.count == 1 && candidates.count == 1 ? candidates.first : nil
    }

    func addGroup(named name: String = "Nouveau groupe") -> UUID {
        let group = SpaceGroup(name: name)
        groups.append(group)
        save()
        return group.id
    }

    func renameGroup(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = clean
        save()
    }

    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        windowOrder.removeValue(forKey: id.uuidString)
        defaults.set(windowOrder, forKey: windowOrderKey)
        for key in windowGroups.keys where windowGroups[key] == id.uuidString {
            windowGroups[key] = ""
        }
        saveWindowGroups()
        save()
    }

    func projectWindows(in group: UUID?) -> [SpaceWindow] {
        windowsByProject(for: [group])[0]
    }

    func windowsByProject(for projects: [UUID?]) -> [[SpaceWindow]] {
        let spaceGroups = Dictionary(
            groups.flatMap { project in
                project.members.compactMap { member -> (DesktopSpace.ID, UUID)? in
                    guard let space = liveSpace(for: member) else { return nil }
                    return (space.id, project.id)
                }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let prioritized = spaces.filter { $0.kind == .fullScreen }
            + spaces.filter { $0.kind == .desktop && $0.isActive }
            + spaces.filter { $0.kind == .desktop && !$0.isActive }
        let locations = Dictionary(
            prioritized.flatMap { space in (windows?.bySpace[space.id] ?? []).map { ($0.id, space) } },
            uniquingKeysWith: { first, _ in first }
        )
        let projectIDs = Set(groups.map(\.id))
        let sections = Dictionary(grouping: windows?.all ?? []) { window -> UUID? in
            if let override = windowGroups[window.key] {
                return UUID(uuidString: override).flatMap { projectIDs.contains($0) ? $0 : nil }
            }
            return locations[window.id].flatMap { spaceGroups[$0.id] }
        }
        return projects.map { group in
            let sorted = (sections[group] ?? []).sorted { first, second in
                let firstFullScreen = locations[first.id]?.kind == .fullScreen
                let secondFullScreen = locations[second.id]?.kind == .fullScreen
                if firstFullScreen != secondFullScreen { return firstFullScreen }
                let order = first.appName.localizedStandardCompare(second.appName)
                return order == .orderedSame ? first.id < second.id : order == .orderedAscending
            }
            guard let order = windowOrder[group?.uuidString ?? ""], !order.isEmpty else { return sorted }
            let byKey = Dictionary(sorted.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let orderedKeys = Set(order)
            return order.compactMap { byKey[$0] } + sorted.filter { !orderedKeys.contains($0.key) }
        }
    }

    func location(for window: SpaceWindow) -> DesktopSpace? {
        let containing = spaces.filter {
            windows?.bySpace[$0.id]?.contains(where: { $0.key == window.key }) == true
        }
        return containing.first { $0.kind == .fullScreen }
            ?? containing.first(where: \.isActive)
            ?? containing.first
    }

    func startAutomaticNaming() {
        // Include windows that the switcher currently filters out.
        seenWindowIDs = WindowInventory.serverWindowIDs()
        pendingWindowIDs.removeAll()
    }

    func stopAutomaticNaming() {
        automaticNamingTask?.cancel()
        automaticNamingTask = nil
        seenWindowIDs = nil
        pendingWindowIDs.removeAll()
    }

    func nameNewWindows() {
        guard !isNaming, WindowFocus.isTrusted else { return }
        guard let seenWindowIDs else {
            startAutomaticNaming()
            return
        }
        guard let spaces = system.readSpaces(), !spaces.isEmpty,
              let catalog = inventory.read(in: spaces, excluding: seenWindowIDs) else { return }
        let observed = catalog.all
        // A window may appear before its application has set the title.
        let newWindows = observed.filter { pendingWindowIDs.contains($0.id) }
        pendingWindowIDs = Set(observed.map(\.id))
        self.seenWindowIDs?.formUnion(newWindows.map(\.id))
        let existingNames = WindowNames.read(for: newWindows)
        let candidates = newWindows.filter { existingNames[$0.key] == nil }
        guard !candidates.isEmpty else { return }
        automaticNamingTask = name(candidates, previousNames: existingNames)
    }

    func refreshNames(for selected: SpaceWindow? = nil) {
        guard !isNaming else { return }
        refresh(includeWindows: true)
        let previousNames = windowNames
        let candidates = (windows?.all ?? []).filter { window in
            selected.map { $0.key == window.key } ?? (previousNames[window.key] == nil)
        }
        guard !candidates.isEmpty else {
            namingStatus = .finished(selected == nil && windows?.all.isEmpty == false
                ? "Fenêtres déjà nommées."
                : "Aucune fenêtre à nommer.")
            return
        }
        name(candidates, previousNames: previousNames)
    }

    @discardableResult
    private func name(_ candidates: [SpaceWindow], previousNames: [String: String]) -> Task<Void, Never> {
        let startedAt = Date()
        namingStatus = .requesting(windowCount: candidates.count, startedAt: startedAt)
        namingLog.notice("Nommage local pour \(candidates.count, privacy: .public) fenêtres")
        return Task(priority: .utility) {
            let suggestions = await LocalWindowNames.suggest(for: candidates)
            guard !Task.isCancelled else {
                namingStatus = .finished("Nommage arrêté.", startedAt: startedAt)
                return
            }
            do {
                refresh(includeWindows: true)
                let live = windows?.all ?? []
                defer { windowNames = WindowNames.read(for: live) }
                let result = try WindowNames.apply(suggestions, for: candidates.map(\.key), to: live,
                                                   previousNames: previousNames)
                namingStatus = .finished(result.summary, startedAt: startedAt)
                namingLog.notice("Noms appliqués : \(result.suggested, privacy: .public) par le modèle local, \(result.fallback, privacy: .public) avec le nom de l’app")
            } catch {
                namingStatus = .finished("Échec du nommage.", startedAt: startedAt)
                namingLog.error("Renommage interrompu : \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    @discardableResult
    func assignWindow(_ key: String, to group: UUID?) -> Bool {
        guard group == nil || groups.contains(where: { $0.id == group }),
              windows?.all.contains(where: { $0.key == key }) == true else { return false }
        // An empty value explicitly places a window in the inbox.
        windowGroups[key] = group?.uuidString ?? ""
        saveWindowGroups()
        return true
    }

    @discardableResult
    func moveWindow(_ key: String, to group: UUID?, before next: String?) -> Bool {
        guard group == nil || groups.contains(where: { $0.id == group }),
              windows?.all.contains(where: { $0.key == key }) == true else { return false }
        let original = projectWindows(in: group).map(\.key)
        var order = original.filter { $0 != key }
        let index = next.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
        order.insert(key, at: index)
        guard order != original else { return true }

        if !original.contains(key) {
            guard assignWindow(key, to: group) else { return false }
        }
        var updated = windowOrder
        for project in updated.keys {
            updated[project]?.removeAll { $0 == key }
        }
        updated[group?.uuidString ?? ""] = order
        windowOrder = updated
        defaults.set(updated, forKey: windowOrderKey)
        return true
    }

    private func mergeSideDockSnapshot() {
        let migrationKey = "importedSideDockSnapshot.v1"
        guard !defaults.bool(forKey: migrationKey),
              let snapshot = defaults.persistentDomain(forName: "local.amazigh.SideDock"),
              let data = snapshot[storageKey] as? Data,
              let imported = try? JSONDecoder().decode([SpaceGroup].self, from: data) else { return }

        // V2 owns existing groups, window assignments and ordering.
        var ids = Set(groups.map(\.id))
        let additions = imported.filter { ids.insert($0.id).inserted }
        if !additions.isEmpty {
            groups.append(contentsOf: additions)
            save()
        }

        let assignments = snapshot[windowGroupKey] as? [String: String] ?? [:]
        for (key, destination) in assignments where windowGroups[key] == nil {
            if destination.isEmpty || UUID(uuidString: destination).map(ids.contains) == true {
                windowGroups[key] = destination
            }
        }
        saveWindowGroups()

        let orders = snapshot[windowOrderKey] as? [String: [String]] ?? [:]
        for (destination, order) in orders where windowOrder[destination] == nil {
            if destination.isEmpty || UUID(uuidString: destination).map(ids.contains) == true {
                windowOrder[destination] = order
            }
        }
        defaults.set(windowOrder, forKey: windowOrderKey)
        defaults.set(true, forKey: migrationKey)
    }

    private func saveWindowGroups() {
        defaults.set(windowGroups, forKey: windowGroupKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(groups) { defaults.set(data, forKey: storageKey) }
    }
}
