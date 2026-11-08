import SwiftUI

struct GroupBar: View {
    @ObservedObject var store: GroupStore
    let openSpace: (DesktopSpace) -> Void
    let openWindow: (SpaceWindow) -> Void
    let close: () -> Void
    let openSetup: () -> Void
    let nativeBackground: Bool

    @State private var query = ""
    @State private var editingGroup: UUID?
    @State private var groupName = ""
    @State private var hoveredGroup: UUID?
    @State private var hoveredRow: String?
    @FocusState private var editingName: Bool
    @State private var drag: DraggedEntry?
    @State private var drop: DropLocation?
    @State private var groupFrames: [String: CGRect] = [:]
    @State private var rowFrames: [String: [String: CGRect]] = [:]
    @State private var projectsViewport = CGRect.zero
    @State private var inboxViewport = CGRect.zero

    private let coordinates = "projectEditor"
    private let inbox = "inbox"
    private let accents: [Color] = [.indigo, .cyan, .purple, .orange]

    private struct DraggedEntry {
        let key: String
        let label: String
        let icon: Image
        var position: CGPoint
    }

    private struct DropLocation: Equatable {
        let group: String
        var beforeWindow: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    projects
                        .frame(width: geometry.size.width * 0.53)
                    Divider()
                    unassigned
                }
            }
            if let message = store.message {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
        }
        .overlay {
            if let drag {
                Label {
                    Text(drag.label).lineLimit(1)
                } icon: {
                    drag.icon.resizable().aspectRatio(contentMode: .fit).frame(width: 25, height: 25)
                }
                .font(.callout.weight(.semibold))
                .padding(9)
                .background(.regularMaterial, in: .rect(cornerRadius: 9))
                .shadow(radius: 7, y: 3)
                .position(drag.position)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .coordinateSpace(name: coordinates)
        .background {
            if !nativeBackground {
                RoundedRectangle(cornerRadius: 27).fill(.regularMaterial)
            }
        }
        .clipShape(.rect(cornerRadius: 27))
        .accessibilityLabel("Organiser les projets")
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                identity
                Spacer(minLength: 8)
                search
                toolbarActions
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    identity
                    Spacer()
                    toolbarActions
                }
                search
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var identity: some View {
        HStack(spacing: 11) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 40, height: 40)
                .background(.indigo.opacity(0.16), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Groupes d’espaces").font(.headline)
                Text("\(windowCount(store.windows?.count ?? 0))  ·  \(store.spaces.count) espaces macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Rechercher une fenêtre…", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Rechercher dans tous les espaces")
            if !query.isEmpty {
                Button("Effacer la recherche", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 140, idealWidth: 240, maxWidth: 340, minHeight: 31)
        .background(.primary.opacity(0.065), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.10)).allowsHitTesting(false) }
    }

    private var toolbarActions: some View {
        HStack(spacing: 12) {
            Button("Groupe", systemImage: "plus") {
                query = ""
                let id = store.addGroup()
                rename(id, name: "")
            }
            .buttonStyle(.bordered)
            .help("Créer un groupe")

            Menu {
                Button("Configurer l’Accessibilité…", systemImage: "accessibility", action: openSetup)
                Button("Ouvrir Mission Control", systemImage: "rectangle.3.group") {
                    close()
                    let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
                Divider()
                Button("Quitter Groupes d’espaces V2") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Options")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Divider().frame(height: 20)

            Button("Fermer", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Fermer (Échap)")
        }
        .fixedSize()
    }

    private var projects: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.groups.isEmpty {
                        Text("Crée un groupe pour y classer tes fenêtres.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                            section(group, accent: accents[index % accents.count])
                                .id(group.id)
                            if index < store.groups.count - 1 { Divider() }
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: editingGroup) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinates)) } action: { projectsViewport = $0 }
    }

    private var unassigned: some View {
        ScrollView {
            section(nil, accent: .secondary)
                .padding(16)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinates)) } action: { inboxViewport = $0 }
    }

    private func section(_ group: SpaceGroup?, accent: Color) -> some View {
        let id = group?.id
        let target = id?.uuidString ?? inbox
        let windows = store.projectWindows(in: id)
        let labels = WindowNames.labels(for: windows, customNames: store.windowNames)
        let visible = windows.filter { matches($0.label) || matches(labels[$0.key] ?? "") }
        let spaces = references(for: group).filter { matches($0.name) }
        let targeted = drop?.group == target

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 11, height: 11).accessibilityHidden(true)
                if let group {
                    groupTitle(group)
                } else {
                    Text("Sans projet").font(.headline)
                }
                Text(windowCount(visible.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 2)
                if let group, let desktop = store.desktopDestination(for: group) {
                    Button("Aller à \(desktop.name)", systemImage: "rectangle.on.rectangle") { openSpace(desktop) }
                        .buttonStyle(.bordered)
                        .lineLimit(1)
                        .help("Aller à \(desktop.name)")
                }
            }
            .frame(minHeight: 38)
            .padding(.bottom, 6)

            ForEach(visible) { window in
                Divider()
                windowRow(window, label: labels[window.key] ?? window.label, groupID: id)
                    .overlay(alignment: .top) {
                        if targeted, drop?.beforeWindow == window.key {
                            Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                        }
                    }
            }
            ForEach(spaces) { reference in
                Divider()
                spaceRow(reference, groupID: id)
            }
            if visible.isEmpty && spaces.isEmpty {
                if let group, query.isEmpty {
                    addWindows(to: group)
                } else {
                    Text(query.isEmpty ? "Aucune fenêtre à classer" : "Aucun résultat")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
            }
            if targeted, drop?.beforeWindow == nil {
                Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 2)
        .background(targeted ? accent.opacity(0.10) : .clear, in: .rect(cornerRadius: 9))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinates)) } action: { groupFrames[target] = $0 }
        .onDisappear { groupFrames.removeValue(forKey: target) }
    }

    @ViewBuilder
    private func groupTitle(_ group: SpaceGroup) -> some View {
        if editingGroup == group.id {
            HStack(spacing: 3) {
                TextField("Nom du groupe", text: $groupName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 80, maxWidth: 170)
                    .focused($editingName)
                    .onSubmit(saveName)
                Button("Enregistrer", systemImage: "checkmark", action: saveName)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                Button("Annuler", systemImage: "xmark") { editingGroup = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 3) {
                Text(group.name)
                    .font(.headline)
                    .lineLimit(1)
                    .contextMenu { groupActions(group) }
                Menu {
                    groupActions(group)
                } label: {
                    Image(systemName: "gearshape").accessibilityLabel("Options de \(group.name)")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hoveredGroup == group.id ? 1 : 0)
                .allowsHitTesting(hoveredGroup == group.id)
                .accessibilityHidden(hoveredGroup != group.id)
            }
            .onHover { inside in
                if inside { hoveredGroup = group.id }
                else if hoveredGroup == group.id { hoveredGroup = nil }
            }
        }
    }

    @ViewBuilder
    private func groupActions(_ group: SpaceGroup) -> some View {
        Button("Renommer le groupe…") { rename(group.id, name: group.name) }
        Button("Supprimer le groupe", role: .destructive) { store.deleteGroup(group.id) }
    }

    private func addWindows(to group: SpaceGroup) -> some View {
        let available = store.projectWindows(in: nil)
        let labels = WindowNames.labels(for: available, customNames: store.windowNames)
        return Menu {
            if available.isEmpty {
                Text("Glisse une fenêtre depuis un autre groupe.")
            }
            ForEach(available) { window in
                Button(labels[window.key] ?? window.label) { store.assignWindow(window.key, to: group.id) }
            }
        } label: {
            Label("Ajouter des fenêtres", systemImage: "plus")
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 47)
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .allowsHitTesting(false)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func windowRow(_ window: SpaceWindow, label: String, groupID: UUID?) -> some View {
        let space = store.location(for: window)
        let detail = space?.kind == .fullScreen ? "Plein écran"
            : window.isMinimized ? "Réduite" : space?.name ?? window.appName
        let icon = NSRunningApplication(processIdentifier: window.ownerPID)?.icon
            .map(Image.init(nsImage:)) ?? Image(systemName: "macwindow")
        let key = "window:" + window.key
        let target = groupID?.uuidString ?? inbox
        let remove: (() -> Void)? = groupID.map { _ in { _ = store.assignWindow(window.key, to: nil) } }
        return row(key: key, label: label, detail: detail, icon: icon, open: { openWindow(window) }, remove: remove) { group, before in
            store.moveWindow(window.key, to: group, before: before)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinates)) } action: {
            rowFrames[target, default: [:]][window.key] = $0
        }
        .onDisappear { rowFrames[target]?.removeValue(forKey: window.key) }
    }

    private func spaceRow(_ reference: SpaceReference, groupID: UUID?) -> some View {
        let live = store.liveSpace(for: reference)
        let icon = Image(systemName: reference.kind == .desktop ? "rectangle.on.rectangle" : "arrow.up.left.and.arrow.down.right")
        let open: (() -> Void)? = live.map { space in { openSpace(space) } }
        let remove: (() -> Void)? = groupID.map { group in { store.remove(reference, from: group) } }
        return row(key: "space:" + reference.id, label: reference.name, detail: live == nil ? "Fermé" : "Espace",
                   icon: icon, open: open, remove: remove) { group, _ in
            if let live { _ = store.assign(live, to: group) }
        }
    }

    private func row(key: String, label: String, detail: String, icon: Image, open: (() -> Void)?,
                     remove: (() -> Void)?, assign: @escaping (UUID?, String?) -> Void) -> some View {
        let highlighted = hoveredRow == key && drag == nil
        let content = HStack(spacing: 10) {
            icon.resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 33, height: 33)
                .accessibilityHidden(true)
            Text(label).font(.callout.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 49)
        .contentShape(Rectangle())

        return Group {
            if let open {
                Button(action: open) { content }
                    .buttonStyle(.plain)
                    .overlay {
                        TilePointer(click: open, hover: { inside in
                            if inside { hoveredRow = key }
                            else if hoveredRow == key { hoveredRow = nil }
                        }) { point, offset in
                            let position = CGPoint(x: point.x - offset.width, y: point.y - offset.height)
                            drag = DraggedEntry(key: key, label: label, icon: icon, position: position)
                            drop = destination(at: point, excluding: key)
                        } drop: { point in
                            defer { drag = nil; drop = nil }
                            guard let point, let destination = destination(at: point, excluding: key) else { return }
                            assign(UUID(uuidString: destination.group), destination.beforeWindow)
                        }
                        .accessibilityHidden(true)
                    }
            } else {
                content.foregroundStyle(.secondary)
            }
        }
        .background(highlighted ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 9))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.accentColor.opacity(0.68))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "minus")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(.regularMaterial, in: Circle())
                        .overlay { Circle().strokeBorder(.primary.opacity(0.25)).allowsHitTesting(false) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 30)
                .padding(.top, 4)
                .help("Retirer du projet")
                .accessibilityLabel("Retirer \(label) du projet")
            }
        }
        .opacity(drag?.key == key ? 0.32 : 1)
    }

    private func destination(at point: CGPoint, excluding key: String) -> DropLocation? {
        let target: String
        if inboxViewport.contains(point) {
            target = inbox
        } else {
            guard projectsViewport.contains(point),
                  let group = store.groups.first(where: { groupFrames[$0.id.uuidString]?.contains(point) == true })
            else { return nil }
            target = group.id.uuidString
        }

        let windows = store.projectWindows(in: UUID(uuidString: target))
        let before = windows.first { window in
            guard key != "window:" + window.key, let frame = rowFrames[target]?[window.key] else { return false }
            return frame.midY > point.y
        }
        return DropLocation(group: target, beforeWindow: before?.key)
    }

    private func references(for group: SpaceGroup?) -> [SpaceReference] {
        if let group { return group.members.filter { store.showsSpaceEntry(store.liveSpace(for: $0)) } }
        return store.ungrouped.filter { store.showsSpaceEntry($0) }.map(\.reference)
    }

    private func matches(_ value: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || value.localizedStandardContains(text)
    }

    private func windowCount(_ count: Int) -> String {
        "\(count) fenêtre\(count > 1 ? "s" : "")"
    }

    private func rename(_ id: UUID, name: String) {
        editingGroup = id
        groupName = name
        editingName = true
    }

    private func saveName() {
        if let editingGroup { store.renameGroup(editingGroup, to: groupName) }
        editingGroup = nil
    }
}
