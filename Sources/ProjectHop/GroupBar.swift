import SwiftUI

struct GroupBar: View {
    static let cornerRadius: CGFloat = 27
    static let maximumHeight: CGFloat = 560
    private static let rowHeight: CGFloat = 42
    private static let sectionHeaderHeight: CGFloat = 40
    private static let columnPadding: CGFloat = 14
    private static let emptyHeight: CGFloat = 48
    private static let rowIconSize: CGFloat = 30
    private static let rowInset: CGFloat = 7
    private static let rowSpacing: CGFloat = 10
    private static let closeButtonSize: CGFloat = 28
    private static let closeButtonInset: CGFloat = 4

    @ObservedObject var store: GroupStore
    let openWindow: (SpaceWindow) -> Void
    let closeWindow: (SpaceWindow) -> Void
    let close: () -> Void
    let openSetup: () -> Void
    let resize: (CGFloat) -> Void

    @State private var query = ""
    @State private var editingGroup: UUID?
    @State private var groupName = ""
    @State private var hoveredGroup: UUID?
    @State private var hoveredRow: String?
    @FocusState private var focusedGroup: UUID?
    @State private var drag: DraggedEntry?
    @State private var drop: DropLocation?
    @State private var groupFrames: [String: CGRect] = [:]
    @State private var rowFrames: [String: [String: CGRect]] = [:]
    @State private var projectsViewport = CGRect.zero
    @State private var inboxViewport = CGRect.zero
    @State private var toolbarHeight: CGFloat = 0
    @State private var projectsHeight: CGFloat = 0
    @State private var inboxHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

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

    static func openingSize(for store: GroupStore, available: CGSize) -> CGSize {
        let projects = store.groups
        let sections = store.windowsByProject(for: projects.map { Optional($0.id) } + [nil])
        let projectSections = sections.dropLast()
        let inbox = sections.last ?? []
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        func textWidth(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        func sectionWidth(_ windows: [SpaceWindow], groupName: String? = nil) -> CGFloat {
            let labels = WindowNames.labels(for: windows, customNames: store.windowNames)
            let rowControls = rowIconSize + 2 * rowInset + 2 * rowSpacing + 4 + closeButtonSize + closeButtonInset
            let rowWidth = (labels.values.map(textWidth).max() ?? 0) + rowControls
            let headingControls: CGFloat = groupName == nil ? 37 : 62
            let headingWidth = textWidth(groupName ?? "Sans projet") + textWidth(windowCount(windows.count)) + headingControls
            return min(340, ceil(max(rowWidth, headingWidth) + 2 * columnPadding + 4))
        }
        let widestProject = zip(projects, projectSections).map {
            sectionWidth($0.1, groupName: $0.0.name)
        }.max() ?? 0
        let columnWidth = max(220, widestProject, sectionWidth(inbox))
        let width = min(available.width, 2 * columnWidth + 1)

        func sectionHeight(_ count: Int) -> CGFloat {
            sectionHeaderHeight + (count == 0 ? emptyHeight : CGFloat(count) * (rowHeight + 1))
        }
        let projectsHeight = projectSections.reduce(CGFloat.zero) { height, windows in
            height + sectionHeight(windows.count)
        } + CGFloat(max(0, projects.count - 1)) * 25
        let inboxHeight = sectionHeight(inbox.count)
        let toolbarHeight: CGFloat = width < 600 ? 110 : 69
        let height = toolbarHeight + columnPadding * 2 + max(projectsHeight, inboxHeight)
            + (store.message == nil ? 30 : 50)
        return CGSize(width: width, height: min(available.height, maximumHeight, height))
    }

    private var fittedHeight: CGFloat? {
        guard drag == nil, toolbarHeight > 0, projectsHeight > 0, inboxHeight > 0 else { return nil }
        return ceil(toolbarHeight + 1 + max(projectsHeight, inboxHeight) + footerHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolbarHeight = $0 }
            Divider().frame(height: 1)
            GeometryReader { geometry in
                let columnWidth = max(0, (geometry.size.width - 1) / 2)
                HStack(spacing: 0) {
                    projects.frame(width: columnWidth)
                    Divider().frame(width: 1)
                    unassigned.frame(width: columnWidth)
                }
            }
            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
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
        .onChange(of: fittedHeight, initial: true) { _, height in
            if let height { resize(height) }
        }
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        .accessibilityLabel("Organiser les projets")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 4) {
                if let message = store.message {
                    Text(message).frame(maxWidth: .infinity, alignment: .leading)
                }
                Label("Fermer la fenêtre de l’app", systemImage: "xmark")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
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
            Image(nsImage: ProjectHopIcon.image)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("ProjectHop").font(.headline)
                Text("\(Self.windowCount(store.windows?.count ?? 0))  ·  \(store.spaces.count) espaces macOS")
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

            Button("Nommer les fenêtres avec Apple Intelligence", systemImage: "sparkles") {
                store.refreshNames()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(store.isNaming)
            .help("Nomme les fenêtres sans nom personnalisé avec le modèle local d’Apple")

            Menu {
                Button("Configurer l’Accessibilité…", systemImage: "accessibility", action: openSetup)
                Button("Ouvrir Mission Control", systemImage: "rectangle.3.group") {
                    close()
                    let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
                Divider()
                Button("Quitter ProjectHop") { NSApp.terminate(nil) }
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
                .padding(Self.columnPadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { projectsHeight = $0 }
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
                .padding(Self.columnPadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inboxHeight = $0 }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinates)) } action: { inboxViewport = $0 }
    }

    private func section(_ group: SpaceGroup?, accent: Color) -> some View {
        let id = group?.id
        let target = id?.uuidString ?? inbox
        let windows = store.projectWindows(in: id)
        let labels = WindowNames.labels(for: windows, customNames: store.windowNames)
        let visible = windows.filter { matches($0.label) || matches(labels[$0.key] ?? "") }
        let targeted = drop?.group == target

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 11, height: 11).accessibilityHidden(true)
                if let group {
                    groupTitle(group)
                } else {
                    Text("Sans projet").font(.headline)
                }
                Text(Self.windowCount(visible.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 2)
            }
            .frame(minHeight: Self.sectionHeaderHeight - 6)
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
            if visible.isEmpty {
                if let group, query.isEmpty {
                    addWindows(to: group)
                } else {
                    Text(query.isEmpty ? "Aucune fenêtre à classer" : "Aucun résultat")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Self.emptyHeight)
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
                    .focused($focusedGroup, equals: group.id)
                    .onSubmit(saveName)
                Button("Enregistrer", systemImage: "checkmark", action: saveName)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                Button("Annuler", systemImage: "xmark", action: stopRenaming)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 3) {
                Text(group.name)
                    .font(.headline)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { rename(group.id, name: group.name) }
                    .help("Double-clique pour renommer le groupe")
                    .contextMenu { groupActions(group) }
                Button("Supprimer le groupe \(group.name)", systemImage: "trash", role: .destructive) {
                    store.deleteGroup(group.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .frame(width: 22, height: 22)
                .help("Supprimer \(group.name)")
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
                .frame(maxWidth: .infinity, minHeight: Self.emptyHeight)
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
        let icon = NSRunningApplication(processIdentifier: window.ownerPID)?.icon
            .map(Image.init(nsImage:)) ?? Image(systemName: "macwindow")
        let key = window.key
        let target = groupID?.uuidString ?? inbox
        let highlighted = hoveredRow == key && drag == nil
        let tile = Button { openWindow(window) } label: {
            HStack(spacing: Self.rowSpacing) {
                icon.resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.rowIconSize, height: Self.rowIconSize)
                    .accessibilityHidden(true)
                Text(label).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, Self.rowInset)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .overlay {
            TilePointer(click: { openWindow(window) }) { point, offset in
                let position = CGPoint(x: point.x - offset.width, y: point.y - offset.height)
                drag = DraggedEntry(key: key, label: label, icon: icon, position: position)
                drop = destination(at: point, excluding: key)
            } drop: { point in
                defer { drag = nil; drop = nil }
                guard let point, let destination = destination(at: point, excluding: key) else { return }
                store.moveWindow(key, to: UUID(uuidString: destination.group), before: destination.beforeWindow)
            }
            .accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
            if highlighted, groupID != nil {
                Color.clear.frame(width: Self.rowIconSize, height: Self.rowIconSize)
                    .overlay(alignment: .topTrailing) {
                        Button { store.assignWindow(key, to: nil) } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 16, height: 16)
                                .background(.regularMaterial, in: Circle())
                                .overlay { Circle().strokeBorder(.primary.opacity(0.25)).allowsHitTesting(false) }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Retirer du projet")
                        .accessibilityLabel("Retirer \(label) du projet")
                    }
                    .padding(.leading, Self.rowInset)
            }
        }

        return HStack(spacing: 0) {
            tile
            Button { closeWindow(window) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: Self.closeButtonSize, height: Self.closeButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Fermer la fenêtre")
            .accessibilityLabel("Fermer \(label)")
            .disabled(drag != nil)
            .padding(.trailing, Self.closeButtonInset)
        }
        .background {
            RowHover { inside in
                if inside { hoveredRow = key }
                else if hoveredRow == key { hoveredRow = nil }
            }
            .accessibilityHidden(true)
        }
        .background(highlighted ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 9))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.accentColor.opacity(0.68))
                    .allowsHitTesting(false)
            }
        }
        .opacity(drag?.key == key ? 0.32 : 1)
        .contextMenu {
            Button("Renommer avec Apple Intelligence", systemImage: "sparkles") { store.refreshNames(for: window) }
                .disabled(store.isNaming)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinates)) } action: {
            rowFrames[target, default: [:]][key] = $0
        }
        .onDisappear {
            rowFrames[target]?.removeValue(forKey: key)
            if hoveredRow == key { hoveredRow = nil }
        }
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
            guard key != window.key, let frame = rowFrames[target]?[window.key] else { return false }
            return frame.midY > point.y
        }
        return DropLocation(group: target, beforeWindow: before?.key)
    }

    private func matches(_ value: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || value.localizedStandardContains(text)
    }

    private static func windowCount(_ count: Int) -> String {
        "\(count) fenêtre\(count > 1 ? "s" : "")"
    }

    private func rename(_ id: UUID, name: String) {
        editingGroup = id
        groupName = name
        focusedGroup = id
    }

    private func saveName() {
        if let editingGroup { store.renameGroup(editingGroup, to: groupName) }
        stopRenaming()
    }

    private func stopRenaming() {
        focusedGroup = nil
        editingGroup = nil
    }
}
