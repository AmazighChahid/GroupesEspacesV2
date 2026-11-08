import AppKit
import SwiftUI

struct SetupView: View {
    let finish: () -> Void

    @State private var accessibilityAllowed = WindowFocus.isTrusted
    @State private var claudeExecutable: URL?
    @State private var claudeConnected: Bool?
    @State private var checkingClaude = true
    @State private var checkID = 0
    @State private var commandCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bienvenue dans Groupes d’espaces V2").font(.title2.bold())
                Text("Configure le passage entre tes fenêtres et le renommage avec Claude.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                HStack(spacing: 12) {
                    DraggableAppIcon()
                        .frame(width: 58, height: 58)
                        .help("Glisser Groupes d’espaces V2 dans les réglages")
                        .accessibilityLabel("Icône de Groupes d’espaces V2 à glisser")
                    VStack(alignment: .leading, spacing: 7) {
                        if accessibilityAllowed {
                            Label("Accessibilité autorisée", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Le sélecteur peut ouvrir la fenêtre choisie.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Glisse cette icône dans la liste des réglages, puis active l’interrupteur.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Ouvrir les réglages d’accessibilité") { WindowFocus.requestAccess() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            } label: {
                Label("Accessibilité", systemImage: "accessibility")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(claudeStatus, systemImage: claudeConnected == true ? "checkmark.circle.fill" : "terminal")
                        .foregroundStyle(claudeConnected == true ? Color.green : Color.secondary)
                    Text(commandCopied
                         ? "Colle la commande dans Terminal, connecte-toi, puis clique sur Vérifier."
                         : "Facultatif. Le renommage transmet les titres des fenêtres à Claude à ta demande.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let claudeExecutable, claudeConnected != true, !checkingClaude {
                            Button("Connexion dans Terminal…") { copyLoginCommand(for: claudeExecutable) }
                        } else if claudeExecutable == nil, !checkingClaude {
                            Link("Installer Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                        }
                        Spacer(minLength: 6)
                        Button("Vérifier") { checkID += 1 }
                            .disabled(checkingClaude)
                        Menu {
                            Button("Choisir l’exécutable claude…", action: chooseClaude)
                            Button("Utiliser la détection automatique") {
                                ClaudeWindowNames.configuredExecutable = nil
                                checkID += 1
                            }
                            .disabled(ClaudeWindowNames.configuredExecutable == nil)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .accessibilityLabel("Emplacement de Claude Code")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Claude Code", systemImage: "sparkles")
            }

            HStack {
                Spacer()
                Button(accessibilityAllowed ? "Terminer" : "Continuer sans l’autorisation", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 470)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            accessibilityAllowed = WindowFocus.isTrusted
        }
        .task(id: checkID) {
            checkingClaude = true
            let executable = ClaudeWindowNames.executable
            let connected = await Task.detached(priority: .utility) {
                executable.flatMap { ClaudeWindowNames.isAuthenticated(using: $0) }
            }.value
            guard !Task.isCancelled else { return }
            claudeExecutable = executable
            claudeConnected = connected
            checkingClaude = false
            if connected == true { commandCopied = false }
        }
    }

    private var claudeStatus: String {
        if checkingClaude { return "Vérification en cours…" }
        if claudeExecutable == nil { return "Exécutable claude introuvable" }
        switch claudeConnected {
        case true?: return "Claude Code connecté"
        case false?: return "Connexion requise"
        case nil: return "Connexion impossible à vérifier"
        }
    }

    private func chooseClaude() {
        let picker = NSOpenPanel()
        picker.message = "Choisis l’exécutable de Claude Code."
        picker.canChooseDirectories = false
        picker.directoryURL = claudeExecutable?.deletingLastPathComponent()
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "Ce fichier n’est pas exécutable."
            alert.informativeText = "Sélectionne le fichier installé par Claude Code."
            alert.runModal()
            return
        }
        ClaudeWindowNames.configuredExecutable = url
        checkID += 1
    }

    private func copyLoginCommand(for executable: URL) {
        let path = executable.path.replacingOccurrences(of: "'", with: "'\\''")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("'\(path)' auth login", forType: .string)
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: .init()
        )
        commandCopied = true
    }
}

private struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconView {
        let view = AppIconView()
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage.copy() as? NSImage
        icon?.size = NSSize(width: 58, height: 58)
        view.image = icon
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ view: AppIconView, context: Context) {}

    final class AppIconView: NSImageView, NSDraggingSource {
        private var didStartDrag = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            didStartDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !didStartDrag else { return }
            didStartDrag = true
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}
