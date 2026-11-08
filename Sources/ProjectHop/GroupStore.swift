import AppKit
import SwiftUI

struct SpaceGroup: Codable, Identifiable {
    var id = UUID()
    var name: String
    var members: [SpaceReference] = []
    var lastVisited: String?
}

@MainActor
final class GroupStore: ObservableObject {
    @Published private(set) var groups: [SpaceGroup]
    @Published private(set) var spaces: [DesktopSpace] = []
    @Published private(set) var windows: WindowCatalog?
    @Published private(set) var windowNames: [String: String] = [:]
    @Published private(set) var windowGroups: [String: String]
    @Published private var windowOrder: [String: [String]]
    @Published var message: String?

    private let system: SpaceSystem
    private let inventory: WindowInventory
    private let defaults: UserDefaults
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
