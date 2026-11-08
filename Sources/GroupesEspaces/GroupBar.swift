import SwiftUI

struct GroupBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: GroupStore
    let openSpace: (DesktopSpace) -> Void
    let openWindow: (SpaceWindow) -> Void
    let close: () -> Void
    @ObservedObject var presentation: SwitcherPresentation
    let setEditing: (Bool) -> Void
    let openSetup: () -> Void
    let resize: (CGSize) -> Void

    @State private var editingGroup: UUID?
    @State private var editingWindow: SpaceWindow?
    @State private var dropLocation: DropLocation?
    @State private var projectFrames: [String: CGRect] = [:]
    @State private var windowOrigins: [String: CGFloat] = [:]
    @State private var editorViewport: CGRect = .zero
    @State private var tabViewport: CGRect = .zero
    @State private var compactWindowViewport: CGRect = .zero
    @State private var compactWindowOrigin: CGFloat = 0
    @State private var measuredSize: CGSize = .zero
    @State private var draggedTile: DraggedTile?
    @State private var hoveredWindow: String?
    @State private var name = ""
    @FocusState private var editingName: Bool
    @FocusState private var editingSearch: Bool
    @State private var selectedProject: String?
    @State private var selectedItem: String?
    @State private var searching = false
    @State private var query = ""

    private let coordinateName = "projectSwitcher"
    private let inboxTarget = "inbox"
    private let accents: [Color] = [.indigo, .teal, .purple, .orange]
    private var dropTarget: String? { dropLocation?.target }
    private var tileWidth: CGFloat { presentation.isEditing ? 88 : 100 }
    private var tileHeight: CGFloat { presentation.isEditing ? 76 : 120 }
    private var tileSpacing: CGFloat { presentation.isEditing ? 8 : 12 }
    private var selectionFill: Color {
        colorScheme == .dark ? Color(white: 0.42).opacity(0.68) : Color(white: 0.36).opacity(0.46)
    }

    private struct DraggedTile {
        let key: String
        let name: String
        let icon: Image
        let isAppIcon: Bool
        let center: CGPoint
    }

    private struct DropLocation: Equatable {
        let target: String
        var beforeWindow: String? = nil
    }

    var body: some View {
        SwitcherFit(limit: presentation.availableSize) {
            if presentation.isEditing {
                editor
            } else {
                compact
            }
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            measuredSize = size
            if draggedTile == nil { resize(size) }
        }
        .overlay(alignment: .topLeading) {
            if let draggedTile {
                tileLabel(name: draggedTile.name, detail: "", icon: draggedTile.icon, isAppIcon: draggedTile.isAppIcon)
                    .frame(width: tileWidth, height: tileHeight)
                    .background(.thinMaterial, in: .rect(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
                    .scaleEffect(1.06)
                    .position(draggedTile.center)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .coordinateSpace(name: coordinateName)
        .onReceive(presentation.keys) { navigate($0) }
        .onReceive(presentation.dismiss) {
            hoveredWindow = nil
            clearDrag()
        }
        .onChange(of: presentation.isEditing) { _, editing in
            hoveredWindow = nil
            clearDrag()
            if editing && searching { toggleSearch() }
            if !editing { endRenaming() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Groupes d’espaces")
    }

    private var editor: some View {
        let maxWidth = max(1, min(presentation.availableSize.width, 1100) - 40)
        let groupWidths = store.groups.map { editorProjectWidth($0.id) }
        let stripWidth = groupWidths.reduce(0, +) + CGFloat(max(0, groupWidths.count - 1)) * 10
        let inboxWidth = editorProjectWidth(nil)
        let headerWidth: CGFloat = editingGroup != nil || editingWindow != nil ? 665 : 575
        let width = min(maxWidth, max(headerWidth, stripWidth, inboxWidth))

        return VStack(alignment: .leading, spacing: 10) {
            header
            ViewThatFits(in: .vertical) {
                editorProjects(width: width, groupWidths: groupWidths, inboxWidth: inboxWidth)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    editorProjects(width: width, groupWidths: groupWidths, inboxWidth: inboxWidth)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateName)) } action: {
                editorViewport = $0
            }
            footer
        }
        .frame(width: width)
        .padding(12)
        .modifier(SwitcherGlass(radius: 26))
        .padding(8)
    }

    private func editorProjects(width: CGFloat, groupWidths: [CGFloat], inboxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.groups.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                            projectRow(group, accent: accents[index % accents.count])
                                .frame(width: min(width, groupWidths[index]))
                        }
                    }
                }
            }
            projectRow(nil, accent: .secondary)
                .frame(width: min(width, inboxWidth))
        }
    }

    private func editorProjectWidth(_ group: UUID?) -> CGFloat {
        let tiles = store.projectWindows(in: group).count + references(for: group).count
        return max(190, CGFloat(tiles) * tileWidth + CGFloat(max(0, tiles - 1)) * tileSpacing + 22)
    }

    private var compact: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 0) { compactSurfaces }
            } else {
                compactSurfaces
            }
        }
        .padding(8)
    }

    private var compactSurfaces: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    projectTabs.fixedSize(horizontal: true, vertical: false)
                    ScrollView(.horizontal) {
                        projectTabs
                    }
                    .scrollIndicators(.hidden)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateName)) } action: {
                    tabViewport = $0
                }
                optionsMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .modifier(SwitcherGlass(radius: 25))

            VStack(spacing: 4) {
                if searching {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        TextField("Chercher dans ce projet", text: $query)
                            .textFieldStyle(.plain)
                            .frame(idealWidth: 220, maxWidth: 250)
                            .focused($editingSearch)
                            .onSubmit { navigate(.open, fromSearch: true) }
                        Button("Fermer", systemImage: "xmark") { toggleSearch() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                    }
                    .font(.callout)
                    .padding(.horizontal, 5)
                }
                HStack(spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        compactTiles.fixedSize(horizontal: true, vertical: false)
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                compactTiles
                            }
                            .scrollIndicators(.hidden)
                            .onChange(of: highlightedItem, initial: true) { _, key in
                                if let key { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(key, anchor: .center) } }
                            }
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateName)) } action: {
                        compactWindowViewport = $0
                    }
                    Divider().frame(height: 53)
                    VStack(spacing: 11) {
                        Button(action: toggleSearch) { Image(systemName: "magnifyingglass") }
                            .help("Chercher dans le projet")
                            .accessibilityLabel("Chercher")
                        Button { setEditing(true) } label: { Image(systemName: "paintbrush") }
                            .help("Organiser les projets et les fenêtres")
                            .accessibilityLabel("Organiser les projets")
                    }
                    .font(.system(size: 18, weight: .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 5)
                }
                if let message = store.message {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).help(message)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 23)
            .padding(.bottom, 7)
            .modifier(SwitcherGlass(radius: 40))
        }
    }

    private var projectTabs: some View {
        HStack(spacing: 7) {
            ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                projectTab(group.name, target: group.id.uuidString,
                           count: store.projectWindows(in: group.id).count,
                           color: accents[index % accents.count])
                    .contextMenu {
                        Button("Renommer le projet…") {
                            setEditing(true)
                            beginRenaming(group.id, currentName: group.name)
                        }
                    }
            }
            Button(action: createGroup) {
                Label("Nouveau groupe", systemImage: "plus")
                    .font(.subheadline)
                    .padding(.horizontal, 10)
                    .frame(height: 31)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            projectTab("Sans projet", target: inboxTarget,
                       count: store.projectWindows(in: nil).count, color: .secondary)
        }
        .padding(4)
    }

    private var compactTiles: some View {
        HStack(spacing: tileSpacing) {
            windowRows(currentWindows, groupID: currentGroupID)
            if !currentWindows.isEmpty && !currentReferences.isEmpty {
                Divider().frame(width: 1, height: 53).padding(.horizontal, 3)
            }
            ForEach(currentReferences) { member in
                spaceEntry(member, live: store.liveSpace(for: member), groupID: currentGroupID)
            }
            if currentWindows.isEmpty && currentReferences.isEmpty {
                Text(query.isEmpty ? "Aucune fenêtre dans ce projet" : "Aucun résultat")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .frame(minHeight: 70)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(coordinateName)).minX } action: {
            compactWindowOrigin = $0
        }
    }

    private func projectTab(_ title: String, target: String, count: Int, color: Color) -> some View {
        let selected = activeProject == target
        return Button {
            selectProject(target)
        } label: {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text(count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.primary.opacity(0.74))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selectionFill.opacity(dropTarget == target ? 0.85 : selected ? 0.50 : 0), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(selected || dropTarget == target ? 0.32 : 0)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateName)) } action: {
            projectFrames["compact:" + target] = $0
        }
        .onDisappear { projectFrames.removeValue(forKey: "compact:" + target) }
    }

    private var activeProject: String {
        let ids = store.groups.map { $0.id.uuidString }
        if let selectedProject, selectedProject == inboxTarget || ids.contains(selectedProject) {
            return selectedProject
        }
        return ids.first ?? inboxTarget
    }

    private var currentGroupID: UUID? { UUID(uuidString: activeProject) }

    private var currentWindows: [SpaceWindow] {
        store.projectWindows(in: currentGroupID).filter { window in
            query.isEmpty || [window.label, store.windowNames[window.key] ?? ""].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var currentReferences: [SpaceReference] {
        references(for: currentGroupID).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var quickKeys: [String] {
        currentWindows.map { "window:" + $0.key } +
            currentReferences.filter { store.liveSpace(for: $0) != nil }.map { "space:" + $0.id }
    }

    private var highlightedItem: String? {
        if let selectedItem, quickKeys.contains(selectedItem) { return selectedItem }
        return quickKeys.first
    }

    private func references(for group: UUID?) -> [SpaceReference] {
        if let group {
            return store.groups.first { $0.id == group }?.members.filter {
                store.showsSpaceEntry(store.liveSpace(for: $0))
            } ?? []
        }
        return store.ungrouped.filter { store.showsSpaceEntry($0) }.map(\.reference)
    }

    private func selectProject(_ id: String) {
        selectedProject = id
        selectedItem = nil
    }

    private func navigate(_ key: SwitcherPresentation.Key, fromSearch: Bool = false) {
        guard !presentation.isEditing, !editingSearch || fromSearch else { return }
        switch key {
        case .nextProject, .previousProject:
            let projects = store.groups.map { $0.id.uuidString } + [inboxTarget]
            guard let index = projects.firstIndex(of: activeProject) else { return }
            let step = key == .nextProject ? 1 : -1
            selectProject(projects[(index + step + projects.count) % projects.count])
        case .next, .previous:
            let keys = quickKeys
            guard let highlightedItem, let index = keys.firstIndex(of: highlightedItem) else { return }
            let step = key == .next ? 1 : -1
            selectedItem = keys[(index + step + keys.count) % keys.count]
        case .open:
            guard let highlightedItem else { return }
            if let window = currentWindows.first(where: { "window:" + $0.key == highlightedItem }) {
                openWindow(window)
            } else if let member = currentReferences.first(where: { "space:" + $0.id == highlightedItem }),
                      let live = store.liveSpace(for: member) {
                openSpace(live)
            }
        }
    }

    private func toggleSearch() {
        searching.toggle()
        editingSearch = searching
        if !searching { query = "" }
    }

    private func createGroup() {
        let id = store.addGroup()
        selectProject(id.uuidString)
        setEditing(true)
        beginRenaming(id, currentName: "")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 35, height: 35)
                .background(.indigo.opacity(0.12), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Groupes d’espaces").font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if editingGroup != nil || editingWindow != nil {
                TextField(editingWindow == nil ? "Nom du groupe" : "Nom de la fenêtre", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($editingName)
                    .onSubmit(commitName)
                Button("OK", action: commitName)
                    .disabled(editingWindow == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Annuler", action: endRenaming)
            } else {
                Button {
                    let id = store.addGroup()
                    beginRenaming(id, currentName: "")
                } label: {
                    Label("Nouveau groupe", systemImage: "plus")
                }
            }

            Button {
                store.refreshNames()
            } label: {
                if store.isNaming {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Actualiser les noms", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isNaming)
            .help("Envoie les titres disponibles des fenêtres sans nom à Claude Code")

            optionsMenu
            Button {
                endRenaming()
                setEditing(false)
            } label: {
                Image(systemName: "paintbrush.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Revenir au sélecteur compact")
            .accessibilityLabel("Revenir au sélecteur compact")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 23, height: 23)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Fermer la barre")
            .help("Fermer la barre (Échap)")
        }
    }

    private var optionsMenu: some View {
        Menu {
            if store.canOpenWindows {
                Text("Accessibilité autorisée")
            }
            Button("Configuration…", systemImage: "gearshape", action: openSetup)
            Button("Ouvrir Mission Control", systemImage: "rectangle.3.group") {
                close()
                let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
            Divider()
            Button("Quitter Groupes d’espaces") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Options")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(presentation.shortcut ?? "Options")
    }

    private func projectRow(_ group: SpaceGroup?, accent: Color) -> some View {
        let groupID = group?.id
        let title = group?.name ?? "Sans projet"
        let projectWindows = store.projectWindows(in: groupID)
        let entries = references(for: groupID)
        let active = projectWindows.contains { store.location(for: $0)?.isActive == true }
        let target = groupID?.uuidString ?? inboxTarget

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                if let group, let destination = store.destination(for: group) {
                    Button { openSpace(destination) } label: { Text(title).font(.subheadline.weight(.semibold)) }
                        .buttonStyle(.plain)
                        .help("Ouvrir \(destination.name)")
                } else {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Text("\(projectWindows.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(projectWindows.count) fenêtres")
                Spacer()
                if let group {
                    Menu {
                        Button("Renommer…") { beginRenaming(group.id, currentName: group.name) }
                        Button("Supprimer le groupe", role: .destructive) {
                            if editingGroup == group.id { endRenaming() }
                            store.deleteGroup(group.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .accessibilityLabel("Options de \(title)")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if entries.isEmpty && projectWindows.isEmpty && !showsInsertion(in: target) {
                Text(group == nil ? "Aucune fenêtre à classer" : "Dépose une fenêtre ici")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        windowRows(projectWindows, groupID: groupID)
                        ForEach(entries) { member in
                            spaceEntry(member, live: store.liveSpace(for: member), groupID: groupID)
                        }
                    }
                    .padding(1)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(coordinateName)).minX + 1 } action: {
                        windowOrigins[target] = $0
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(dropTarget == target ? 0.23 : 0.085), in: .rect(cornerRadius: 13))
        .contentShape(.rect(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(accent.opacity(active || dropTarget == target ? 0.46 : 0.15))
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateName)) } action: {
            projectFrames["edit:" + target] = $0
        }
        .onDisappear { projectFrames.removeValue(forKey: "edit:" + target) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func spaceEntry(_ member: SpaceReference, live: DesktopSpace?, groupID: UUID?) -> some View {
        let key = "space:" + member.id
        return tile(key: key) { selected in
            if let live {
                let icon = Image(systemName: live.kind == .desktop ? "rectangle.on.rectangle" : "arrow.up.left.and.arrow.down.right")
                Button { openSpace(live) } label: {
                    tileLabel(
                        name: live.name, detail: live.kind == .fullScreen ? "Plein écran" : "Espace",
                        icon: icon, selected: selected
                    )
                }
                .buttonStyle(.plain)
                .overlay {
                    pointer(key: key, name: live.name, icon: icon, click: { openSpace(live) }) { group, _ in
                        store.assign(live, to: group)
                    }
                }
            } else {
                tileLabel(name: member.name, detail: "Fermé", icon: Image(systemName: "rectangle.slash"), selected: selected)
                    .foregroundStyle(.secondary)
            }
        } menu: {
            assignmentMenu(space: live, member: member, groupID: groupID)
        }
    }

    private func windowRows(_ windows: [SpaceWindow], groupID: UUID?) -> some View {
        let labels = WindowNames.labels(for: windows, customNames: store.windowNames)
        let target = groupID?.uuidString ?? inboxTarget
        let insertion = showsInsertion(in: target) ? dropLocation : nil
        return Group {
            ForEach(windows) { window in
                let label = labels[window.key] ?? window.label
                let lifted = draggedTile?.key == "window:" + window.key && (presentation.isEditing || insertion != nil)
                windowRow(window, label: label, groupID: groupID)
                    .frame(width: lifted ? 0 : tileWidth)
                    .padding(.leading, insertion?.beforeWindow == window.key ? tileWidth + tileSpacing : 0)
            }
            if let insertion, insertion.beforeWindow == nil {
                Color.clear.frame(width: tileWidth, height: tileHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func windowRow(_ window: SpaceWindow, label: String, groupID: UUID?) -> some View {
        let location = store.location(for: window)
        let detail = location?.kind == .fullScreen ? "Plein écran"
            : window.isMinimized ? "Réduite" : location?.name ?? window.appName
        let appIcon = NSRunningApplication(processIdentifier: window.ownerPID)?.icon
        let icon = appIcon.map(Image.init(nsImage:)) ?? Image(systemName: "macwindow")
        let key = "window:" + window.key
        let hovered = draggedTile == nil && hoveredWindow == key

        return tile(key: key, hovered: hovered) { selected in
            Button { openWindow(window) } label: {
                tileLabel(name: label, detail: detail, icon: icon, isAppIcon: appIcon != nil,
                          selected: selected, hovered: hovered)
            }
            .buttonStyle(.plain)
            .overlay {
                pointer(key: key, name: label, icon: icon, isAppIcon: appIcon != nil,
                        click: { openWindow(window) }, hover: { inside in
                            if inside, draggedTile == nil {
                                hoveredWindow = key
                            } else if hoveredWindow == key {
                                hoveredWindow = nil
                            }
                        }) { group, before in
                    store.moveWindow(window.key, to: group, before: before)
                }
            }
            .help(label == window.label ? label : "\(label) · \(window.label)")
            .accessibilityHint("Met cette fenêtre au premier plan")
        } menu: {
            Menu {
                Button("Renommer la fenêtre…") {
                    if !presentation.isEditing { setEditing(true) }
                    beginWindowRenaming(window)
                }
                Button("Actualiser le nom avec Claude") { store.refreshNames(for: window) }
                    .disabled(store.isNaming)
                if !store.groups.isEmpty {
                    Divider()
                    ForEach(store.groups.filter { $0.id != groupID }) { group in
                        Button("Classer dans \(group.name)") { store.assignWindow(window.key, to: group.id) }
                    }
                    if groupID != nil {
                        Button("Mettre dans Sans projet") { store.assignWindow(window.key, to: nil) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("Options de \(label)")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .overlay(alignment: .topTrailing) {
            if hovered, groupID != nil {
                Button {
                    if store.assignWindow(window.key, to: nil) { hoveredWindow = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                        .overlay { Circle().strokeBorder(.primary.opacity(0.2)).allowsHitTesting(false) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
                .padding(.trailing, presentation.isEditing ? 20 : 1)
                .accessibilityLabel("Retirer \(label) du projet")
                .help("Mettre dans Sans projet")
            }
        }
        .onDisappear {
            if hoveredWindow == key { hoveredWindow = nil }
        }
    }

    private func pointer(key: String, name: String, icon: Image, isAppIcon: Bool = false, click: @escaping () -> Void,
                         hover: ((Bool) -> Void)? = nil,
                         assign: @escaping (UUID?, String?) -> Bool) -> some View {
        TilePointer(click: click, hover: hover) { point, offset in
            hoveredWindow = nil
            draggedTile = DraggedTile(key: key, name: name, icon: icon, isAppIcon: isAppIcon,
                                     center: CGPoint(x: point.x - offset.width, y: point.y - offset.height))
            let location = destination(at: point, for: key)
            if dropLocation != location {
                withAnimation(.easeOut(duration: 0.14)) { dropLocation = location }
            }
        } drop: { point in
            defer { clearDrag() }
            guard let point, let location = destination(at: point, for: key) else { return }
            let group = UUID(uuidString: location.target)
            if assign(group, location.beforeWindow), !presentation.isEditing, activeProject != location.target {
                selectProject(location.target)
            }
        }
        .accessibilityHidden(true)
    }

    private func clearDrag() {
        guard draggedTile != nil else { return }
        draggedTile = nil
        dropLocation = nil
        resize(measuredSize)
    }

    private func showsInsertion(in target: String) -> Bool {
        draggedTile?.key.hasPrefix("window:") == true && dropLocation?.target == target
    }

    private func destination(at point: CGPoint, for key: String) -> DropLocation? {
        let window = key.hasPrefix("window:")
        if !presentation.isEditing, window, compactWindowViewport.contains(point) {
            return insertion(at: point.x, target: activeProject, excluding: key)
        }
        guard (presentation.isEditing ? editorViewport : tabViewport).contains(point) else { return nil }
        let prefix = presentation.isEditing ? "edit:" : "compact:"
        guard let frame = projectFrames.first(where: { $0.key.hasPrefix(prefix) && $0.value.contains(point) }) else {
            return nil
        }
        let target = String(frame.key.dropFirst(prefix.count))
        if presentation.isEditing, window { return insertion(at: point.x, target: target, excluding: key) }
        return DropLocation(target: target)
    }

    private func insertion(at x: CGFloat, target: String, excluding key: String) -> DropLocation {
        let windows = presentation.isEditing ? store.projectWindows(in: UUID(uuidString: target)) : currentWindows
        let keys = windows.map(\.key)
            .filter { "window:" + $0 != key }
        let origin = presentation.isEditing ? windowOrigins[target] : compactWindowOrigin
        guard let origin else { return DropLocation(target: target, beforeWindow: keys.first) }
        let slot = max(0, Int((x - origin) / (tileWidth + tileSpacing)))
        return DropLocation(target: target, beforeWindow: slot < keys.count ? keys[slot] : nil)
    }

    private func tile<Content: View, Actions: View>(
        key: String, hovered: Bool = false,
        @ViewBuilder content: (Bool) -> Content, @ViewBuilder menu: () -> Actions
    ) -> some View {
        let selected = !presentation.isEditing && highlightedItem == key
        return content(selected)
            .frame(width: tileWidth, height: tileHeight)
            .background(selectionFill.opacity(presentation.isEditing && hovered ? 0.45 : 0),
                        in: .rect(cornerRadius: 13))
            .overlay(alignment: .topTrailing) {
                if presentation.isEditing { menu().padding(3) }
            }
            .contextMenu { menu() }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .opacity(draggedTile?.key == key ? 0.001 : 1)
            .id(key)
    }

    private func tileLabel(name: String, detail: String, icon: Image,
                           isAppIcon: Bool = false, selected: Bool? = nil, hovered: Bool = false) -> some View {
        VStack(spacing: presentation.isEditing ? 5 : 4) {
            if presentation.isEditing {
                icon.resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.caption)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            } else {
                let iconSize: CGFloat = 90
                // macOS app images include transparent padding around the artwork.
                let canvas: CGFloat = isAppIcon ? 107 : 65
                Color.clear.frame(width: iconSize, height: iconSize)
                    .overlay {
                        icon.resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: canvas, height: canvas)
                    }
                    .frame(width: tileWidth, height: tileWidth)
                    .background(selectionFill.opacity(selected == true ? 1 : hovered ? 0.55 : 0),
                                in: .rect(cornerRadius: 27))
                    .overlay {
                        if hovered {
                            RoundedRectangle(cornerRadius: 27)
                                .strokeBorder(.primary.opacity(0.38), lineWidth: 1.5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityHidden(true)
                Color.clear
                    .frame(width: tileWidth, height: 16)
                    .overlay {
                        if selected != false {
                            Text(name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .frame(width: 148)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityHint(detail)
    }

    private func assignmentMenu(space: DesktopSpace?, member: SpaceReference, groupID: UUID?) -> some View {
        Menu {
            if let space {
                ForEach(store.groups.filter { $0.id != groupID }) { group in
                    Button(group.name) { store.assign(space, to: group.id) }
                }
                if groupID != nil { Divider() }
            }
            if let groupID {
                Button("Retirer du groupe") { store.remove(member, from: groupID) }
            } else if store.groups.isEmpty {
                Text("Crée d’abord un groupe")
            }
        } label: {
            Image(systemName: "ellipsis")
                .padding(3)
                .accessibilityLabel("Classer \(member.name)")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choisir un groupe")
    }

    private var summary: String {
        let spaces = "\(store.spaces.count) espaces"
        guard let count = store.windows?.count else { return spaces }
        return "\(spaces)  ·  \(count) fenêtre\(count == 1 ? "" : "s")"
    }

    private var footer: some View {
        HStack {
            if let message = store.message {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(message)
            } else if store.windows == nil {
                Label("Liste des fenêtres indisponible", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("Clique pour ouvrir une fenêtre · Glisse pour réorganiser")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let shortcut = presentation.shortcut {
                Text(shortcut)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func beginRenaming(_ id: UUID, currentName: String) {
        name = currentName
        editingWindow = nil
        editingGroup = id
        editingName = true
    }

    private func beginWindowRenaming(_ window: SpaceWindow) {
        name = store.windowNames[window.key] ?? ""
        editingGroup = nil
        editingWindow = window
        editingName = true
    }

    private func commitName() {
        if let editingWindow {
            if store.renameWindow(editingWindow, to: name) { endRenaming() }
        } else if let editingGroup, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.renameGroup(editingGroup, to: name)
            endRenaming()
        }
    }

    private func endRenaming() {
        editingGroup = nil
        editingWindow = nil
        editingName = false
    }
}

private struct SwitcherGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let isDark = colorScheme == .dark
        let tone = isDark ? Color(white: 0.10).opacity(0.62) : Color(white: 0.78).opacity(0.58)
        let rim = isDark ? Color.white.opacity(0.20) : Color.black.opacity(0.17)

        glass(content.background(tone, in: shape), in: shape)
            .overlay { shape.strokeBorder(rim, lineWidth: 0.75).allowsHitTesting(false) }
    }

    @ViewBuilder
    private func glass(_ content: some View, in shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct SwitcherFit: Layout {
    let limit: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(limit)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
