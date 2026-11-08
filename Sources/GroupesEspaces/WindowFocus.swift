import AppKit
import ApplicationServices
import Darwin

enum WindowFocus {
    private typealias GetID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static var isTrusted: Bool { AXIsProcessTrusted() }

    enum Result: String, Sendable {
        case focused, notAuthorized, unavailable, missingWindow, raiseFailed, differentWindow, applicationNotActive

        var description: String {
            switch self {
            case .focused: "Fenêtre au premier plan."
            case .notAuthorized: "Cette version attend l’autorisation Accessibilité."
            case .unavailable: "macOS ne permet pas d’identifier la fenêtre."
            case .missingWindow: "La fenêtre n’est pas encore accessible sur ce bureau."
            case .raiseFailed: "L’app n’a pas pu afficher cette fenêtre."
            case .differentWindow: "L’app a gardé une autre fenêtre au premier plan."
            case .applicationNotActive: "La fenêtre est visible, mais macOS n’a pas activé son application."
            }
        }
    }

    @MainActor
    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings() }
    }

    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func raise(pid: pid_t, id: CGWindowID, minimized: Bool) -> Result {
        guard isTrusted else { return .notAuthorized }
        guard let getID = getWindowID else { return .unavailable }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.4)
        guard let window = elements(of: application).first(where: { windowID($0, getID) == id }) else {
            return .missingWindow
        }
        if minimized {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            return .raiseFailed
        }

        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
           let focusedID = windowID(unsafeDowncast(focused, to: AXUIElement.self), getID) {
            return focusedID == id ? .focused : .differentWindow
        }
        return frontVisibleWindowID(pid: pid) == id ? .focused : .differentWindow
    }

    static func frontVisibleWindowID(pid: pid_t) -> CGWindowID? {
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return rows?.first {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
        }?[kCGWindowNumber as String] as? CGWindowID
    }

    static func isWindowVisible(pid: pid_t, id: CGWindowID) -> Bool {
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return rows?.contains {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowNumber as String] as? CGWindowID == id
        } == true
    }

    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        guard isTrusted, let getID = getWindowID else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.4)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return windowID(unsafeDowncast(value, to: AXUIElement.self), getID)
    }

    static func titles(pid: pid_t, ids: Set<CGWindowID>) -> [CGWindowID: String] {
        guard isTrusted, !ids.isEmpty, let getID = getWindowID else { return [:] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var titles: [CGWindowID: String] = [:]
        for window in elements(of: application) {
            guard let id = windowID(window, getID), ids.contains(id) else { continue }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
               let title = value as? String, !title.isEmpty {
                titles[id] = title
            }
        }
        return titles
    }

    private static func elements(of application: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static let getWindowID: GetID? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let framework = dlopen(path, RTLD_LAZY),
              let address = dlsym(framework, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(address, to: GetID.self)
    }()

    private static func windowID(_ element: AXUIElement, _ getID: GetID) -> CGWindowID? {
        var id: CGWindowID = 0
        return getID(element, &id) == .success ? id : nil
    }
}
