import AppKit
import SwiftUI

@MainActor
enum ProjectHopIcon {
    static let image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let front = CGRect(x: 1.5, y: 7.4, width: 10.2, height: 8.2)
            let rear = CGRect(x: 8.3, y: 2.4, width: 10.2, height: 8.2)

            func drawWindow(_ frame: CGRect) {
                context.addPath(CGPath(roundedRect: frame, cornerWidth: 2, cornerHeight: 2, transform: nil))
                let titleBarY = frame.minY + 2.5
                context.move(to: CGPoint(x: frame.minX, y: titleBarY))
                context.addLine(to: CGPoint(x: frame.maxX, y: titleBarY))
                context.strokePath()
            }

            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setFillColor(NSColor.white.cgColor)
            context.setLineWidth(1.25)
            context.setLineCap(.round)

            drawWindow(rear)
            context.setBlendMode(.clear)
            context.addPath(CGPath(roundedRect: front, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.fillPath()
            context.setBlendMode(.normal)
            drawWindow(front)

            let hop = CGMutablePath()
            hop.move(to: CGPoint(x: 5.1, y: 14))
            hop.addCurve(to: CGPoint(x: 15.5, y: 7.1),
                         control1: CGPoint(x: 7.6, y: 10.1), control2: CGPoint(x: 11.9, y: 7.1))

            // Separate the arc from the window edges it crosses.
            context.setBlendMode(.clear)
            context.setLineWidth(2.9)
            context.addPath(hop)
            context.strokePath()
            context.setBlendMode(.normal)
            context.setLineWidth(1.35)
            context.addPath(hop)
            context.strokePath()
            context.fillEllipse(in: CGRect(x: 14.35, y: 5.95, width: 2.3, height: 2.3))
            context.endTransparencyLayer()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct SetupView: View {
    let finish: () -> Void
    let accessGranted: () -> Void

    @State private var accessibilityAllowed = WindowFocus.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bienvenue dans ProjectHop").font(.title2.bold())
                Text("Autorise l’accès à tes fenêtres pour utiliser le sélecteur avec ⌥ Tab.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                HStack(spacing: 12) {
                    DraggableAppIcon()
                        .frame(width: 58, height: 58)
                        .help("Glisser ProjectHop dans les réglages")
                        .accessibilityLabel("Icône de ProjectHop à glisser")

                    VStack(alignment: .leading, spacing: 7) {
                        if accessibilityAllowed {
                            Label("Accessibilité autorisée", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Glisse l’icône dans les réglages d’Accessibilité, puis active l’interrupteur.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Ouvrir les réglages d’Accessibilité", action: WindowFocus.openSettings)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            } label: {
                Label("Accessibilité", systemImage: "accessibility")
            }

            HStack {
                Spacer()
                if accessibilityAllowed {
                    Button("Terminer", action: finish).keyboardShortcut(.defaultAction)
                } else {
                    Button("Continuer sans l’autorisation", action: finish)
                }
            }
        }
        .padding(24)
        .frame(width: 470)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            accessibilityAllowed = WindowFocus.isTrusted
        }
        .onChange(of: accessibilityAllowed) { _, allowed in
            if allowed { accessGranted() }
        }
    }
}

private struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconView {
        let view = AppIconView()
        view.image = ProjectHopIcon.image
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
