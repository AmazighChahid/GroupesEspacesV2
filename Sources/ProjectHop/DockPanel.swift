import AppKit
import QuartzCore

@MainActor
final class DockPanel: NSPanel {
    var changeProject: ((Int) -> Void)?
    private var horizontalDelta: CGFloat = 0
    private var handledGesture = false
    private var lastWheelSwitch: TimeInterval = -.infinity

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers.isEmpty, let changeProject {
            switch event.keyCode {
            case 123:
                changeProject(-1)
                return
            case 124:
                changeProject(1)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            handleHorizontalScroll(event)
        } else {
            super.sendEvent(event)
        }
    }

    private func handleHorizontalScroll(_ event: NSEvent) {
        guard let changeProject else { return }
        if event.phase.contains(.began) || event.phase.contains(.cancelled) || event.phase.contains(.ended) {
            horizontalDelta = 0
            handledGesture = false
        }
        let x = event.scrollingDeltaX
        let y = event.scrollingDeltaY
        guard abs(x) > abs(y) else { return }
        guard event.momentumPhase.isEmpty, !handledGesture else { return }

        if event.phase.isEmpty {
            let now = CACurrentMediaTime()
            guard now - lastWheelSwitch > 0.20 else { return }
            lastWheelSwitch = now
            changeProject(x < 0 ? 1 : -1)
        } else {
            horizontalDelta += x
            if abs(horizontalDelta) >= 6 {
                handledGesture = true
                changeProject(horizontalDelta < 0 ? 1 : -1)
            }
        }
    }
}
