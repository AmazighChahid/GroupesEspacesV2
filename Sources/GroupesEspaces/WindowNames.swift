import Foundation

enum WindowNames {
    private static let directory = URL.applicationSupportDirectory
        .appending(path: "GroupesEspacesV2/WindowNames", directoryHint: .isDirectory)

    private static let originalDirectory = URL.applicationSupportDirectory
        .appending(path: "GroupesEspaces/WindowNames", directoryHint: .isDirectory)

    static func read(for windows: [SpaceWindow]) -> [String: String] {
        var names: [String: String] = [:]
        for window in windows {
            let local = try? String(contentsOf: file(for: window), encoding: .utf8)
            let inherited = originalDirectory.appending(path: "\(window.key).txt")
            let name = local ?? (try? String(contentsOf: inherited, encoding: .utf8))
            if let name, !name.isEmpty { names[window.key] = name }
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

    static func write(_ value: String, for window: SpaceWindow) throws {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 100, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NameError.invalidName
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try name.write(to: file(for: window), atomically: true, encoding: .utf8)
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
    static func run(_ args: [String]) throws {
        let usage = "groupes-espaces fenetres | groupes-espaces renommer <id> <nom>"
        guard args == ["fenetres"]
            || (args.count == 3 && args[0] == "renommer") else {
            throw CommandError(usage)
        }
        let system = SpaceSystem()
        guard let spaces = system.readSpaces(), !spaces.isEmpty,
              let catalog = WindowInventory(system: system).read(in: spaces) else {
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
