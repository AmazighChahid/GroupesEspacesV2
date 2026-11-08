import Darwin
import Foundation

enum WindowNames {
    struct NamingResult {
        fileprivate(set) var suggested = 0
        fileprivate(set) var fallback = 0
        var count: Int { suggested + fallback }

        var message: String {
            guard count > 0 else { return "Aucun nouveau nom appliqué." }
            let summary = "\(count) nom\(count == 1 ? "" : "s") mis à jour"
            if fallback == 0 { return "\(summary) avec le modèle local d’Apple." }
            return "\(summary) (\(suggested) avec Apple Intelligence, \(fallback) avec le nom de l’app)."
        }
    }

    private static let directory = URL.applicationSupportDirectory
        .appending(path: "GroupesEspacesV2/WindowNames", directoryHint: .isDirectory)

    private static let originalDirectory = URL.applicationSupportDirectory
        .appending(path: "GroupesEspaces/WindowNames", directoryHint: .isDirectory)

    static func read(for windows: [SpaceWindow]) -> [String: String] {
        var names: [String: String] = [:]
        for window in windows {
            names[window.key] = name(for: window)
        }
        return names
    }

    static func labels(for windows: [SpaceWindow], customNames: [String: String],
                       includeApplicationName: Bool = true) -> [String: String] {
        var labels = Dictionary(uniqueKeysWithValues: windows.map {
            ($0.key, includeApplicationName ? $0.label : ($0.title ?? $0.appName))
        })
        let untitled = Dictionary(grouping: windows.filter { $0.title == nil }, by: \.appName)
        for peers in untitled.values where peers.count > 1 {
            for (index, window) in peers.sorted(by: { $0.id < $1.id }).enumerated() {
                labels[window.key] = "\(window.appName) \(index + 1)"
            }
        }
        for window in windows {
            if let customName = customNames[window.key] { labels[window.key] = customName }
        }
        return labels
    }

    static func apply(_ suggestions: [String: String], for requestedIDs: [String],
                      to windows: [SpaceWindow], previousNames: [String: String]) throws -> NamingResult {
        let live = Dictionary(uniqueKeysWithValues: windows.map { ($0.key, $0) })
        var reservedNames = Set(read(for: windows).values).union(suggestions.values)
        var result = NamingResult()
        for id in requestedIDs {
            guard let window = live[id] else { continue }
            let proposal = suggestions[id]
            let label = proposal ?? fallbackName(for: window, reserving: &reservedNames)
            guard try write(label, for: window, when: { $0 == previousNames[id] }) else { continue }
            if proposal == nil {
                result.fallback += 1
            } else {
                result.suggested += 1
            }
        }
        return result
    }

    private static func fallbackName(for window: SpaceWindow, reserving names: inout Set<String>) -> String {
        let app = window.appName.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = app.isEmpty ? "Fenêtre" : String(app.prefix(40))
        var label = base
        var number = 1
        while !names.insert(label).inserted {
            number += 1
            label = "\(base) \(number)"
        }
        return label
    }

    @discardableResult
    static func write(_ value: String, for window: SpaceWindow,
                      when canReplace: (String?) -> Bool = { _ in true }) throws -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 100, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NameError.invalidName
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // Compare and write under the same lock across the app and CLI processes.
        let lock = open(directory.path, O_RDONLY | O_EXLOCK | O_CLOEXEC)
        guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lock) }
        guard canReplace(self.name(for: window)) else { return false }
        try name.write(to: file(for: window), atomically: true, encoding: .utf8)
        return true
    }

    private static func name(for window: SpaceWindow) -> String? {
        let local = try? String(contentsOf: file(for: window), encoding: .utf8)
        let inherited = originalDirectory.appending(path: "\(window.key).txt")
        let name = local ?? (try? String(contentsOf: inherited, encoding: .utf8))
        return name?.isEmpty == false ? name : nil
    }

    private static func file(for window: SpaceWindow) -> URL {
        directory.appending(path: "\(window.key).txt")
    }

    private enum NameError: LocalizedError {
        case invalidName

        var errorDescription: String? { "Le nom doit tenir sur une ligne et contenir au plus 100 caractères." }
    }
}

@MainActor
enum WindowCommand {
    static func run(_ args: [String]) async throws {
        let usage = "ProjectHop fenetres | ProjectHop renommer <id> <nom> | ProjectHop actualiser-noms"
        guard args == ["fenetres"] || args == ["actualiser-noms"]
            || (args.count == 3 && args[0] == "renommer") else {
            throw CommandError(usage)
        }
        let system = SpaceSystem()
        let inventory = WindowInventory(system: system)
        guard let spaces = system.readSpaces(), !spaces.isEmpty,
              let catalog = inventory.read(in: spaces) else {
            throw CommandError("Impossible de lire les fenêtres de la session macOS.")
        }
        let windows = catalog.all

        if args[0] == "renommer" {
            guard let window = windows.first(where: { $0.key == args[1] }) else {
                throw CommandError("Fenêtre introuvable. Relance la commande fenetres pour obtenir son identifiant.")
            }
            try WindowNames.write(args[2], for: window)
            return
        }

        let names = WindowNames.read(for: windows)
        if args[0] == "actualiser-noms" {
            let candidates = windows.filter { names[$0.key] == nil }
            let suggestions = await LocalWindowNames.suggest(for: candidates)
            let live = system.readSpaces().flatMap { inventory.read(in: $0) }?.all ?? []
            let result = try WindowNames.apply(suggestions, for: candidates.map(\.key), to: live, previousNames: names)
            print(result.message)
            return
        }
        let entries = windows.map { window in
            let location = spaces.filter { catalog.bySpace[$0.id]?.contains(window) == true }
            return Entry(
                id: window.key, app: window.appName, title: window.title, customName: names[window.key],
                spaces: location.map(\.name), fullScreen: location.contains { $0.kind == .fullScreen },
                minimized: window.isMinimized
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(entries), as: UTF8.self))
    }

    private struct Entry: Encodable {
        let id: String
        let app: String
        let title: String?
        let customName: String?
        let spaces: [String]
        let fullScreen: Bool
        let minimized: Bool
    }

    private struct CommandError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
