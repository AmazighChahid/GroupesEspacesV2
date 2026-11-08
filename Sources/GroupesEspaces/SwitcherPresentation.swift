import Combine
import CoreGraphics

@MainActor
final class SwitcherPresentation: ObservableObject {
    enum Key { case next, previous, nextProject, previousProject, open }

    @Published var isEditing = false
    @Published var shortcut: String?
    @Published var availableSize = CGSize(width: 980, height: 600)
    let keys = PassthroughSubject<Key, Never>()
    let dismiss = PassthroughSubject<Void, Never>()
}
