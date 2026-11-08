import AppKit
import QuartzCore

@MainActor
enum PanelMotion {
    enum Axis: String {
        case x, y
    }

    static let slideDuration = 0.20
    static let morphDuration = 0.27
    static let slideKey = "projectSlide"

    static var isEnabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var easeOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }

    static func slide(on layer: CALayer?, axis: Axis, from start: CGFloat, to end: CGFloat = 0,
                      holdsEnd: Bool = false) {
        let animation = CABasicAnimation(keyPath: "transform.translation.\(axis.rawValue)")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = slideDuration
        animation.timingFunction = easeOut
        if holdsEnd {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer?.add(animation, forKey: slideKey)
    }

    static func morphFrame(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        let eased = 1 - pow(1 - progress, 3)
        return CGRect(x: start.minX + (end.minX - start.minX) * eased,
                      y: start.minY + (end.minY - start.minY) * eased,
                      width: start.width + (end.width - start.width) * eased,
                      height: start.height + (end.height - start.height) * eased)
    }
}
