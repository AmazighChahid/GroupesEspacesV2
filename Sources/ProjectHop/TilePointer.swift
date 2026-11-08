import SwiftUI

struct TilePointer: NSViewRepresentable {
    let click: () -> Void
    let move: (CGPoint, CGSize) -> Void
    let drop: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TilePointerView { TilePointerView() }

    func updateNSView(_ view: TilePointerView, context: Context) {
        view.click = click
        view.move = move
        view.drop = drop
    }
}

final class TilePointerView: NSView {
    var click: (() -> Void)?
    var move: ((CGPoint, CGSize) -> Void)?
    var drop: ((CGPoint?) -> Void)?

    private var start: CGPoint?
    private var grabOffset: CGSize = .zero
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        let clicked = convert(event.locationInWindow, from: nil)
        grabOffset = CGSize(width: clicked.x - bounds.midX,
                            height: isFlipped ? clicked.y - bounds.midY : bounds.midY - clicked.y)
        dragging = false
        drop?(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard window?.isVisible == true, let start, let point = panelPoint(event) else { return }
        if !dragging {
            let current = event.locationInWindow
            guard hypot(current.x - start.x, current.y - start.y) >= 5 else { return }
            dragging = true
        }
        move?(point, grabOffset)
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        if dragging {
            dragging = false
            drop?(window?.isVisible == true ? panelPoint(event) : nil)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            click?()
        }
    }

    private func panelPoint(_ event: NSEvent) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        let x = point.x - content.bounds.minX
        let y = content.isFlipped ? point.y - content.bounds.minY : content.bounds.maxY - point.y
        return CGPoint(x: x, y: y)
    }
}

struct RowHover: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: view, userInfo: nil
        ))
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.changed = changed
    }

    final class TrackingView: NSView {
        var changed: ((Bool) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { changed?(true) }
        override func mouseExited(with event: NSEvent) { changed?(false) }
    }
}
