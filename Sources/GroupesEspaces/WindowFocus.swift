import AppKit
import ApplicationServices
import Darwin
import Synchronization

enum WindowFocus {
    private typealias GetID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CreateFromToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private struct WindowKey: Hashable {
        let pid: pid_t
        let id: CGWindowID
    }

    private struct WindowHandle: @unchecked Sendable {
        let element: AXUIElement
    }

    private static let knownWindows = Mutex<[WindowKey: WindowHandle]>([:])

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
        remember(window, for: WindowKey(pid: pid, id: id))
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

    static func raiseForSpaceTransition(pid: pid_t, id: CGWindowID) async -> AXError {
        let task = Task.detached(priority: .userInitiated) {
            guard isTrusted, let getID = getWindowID else { return AXError.apiDisabled }
            let key = WindowKey(pid: pid, id: id)
            let cached = knownWindows.withLock { $0[key] }?.element
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.25)
            let window = cached.flatMap { windowID($0, getID) == id ? $0 : nil }
                ?? elements(of: application).first { windowID($0, getID) == id }
                ?? findOffSpaceWindow(key, getID: getID)
            guard !Task.isCancelled, let window else { return AXError.invalidUIElement }
            AXUIElementSetMessagingTimeout(window, 0.25)
            let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if result == .success {
                remember(window, for: key)
            } else if result == .invalidUIElement {
                knownWindows.withLock { $0.removeValue(forKey: key) }
            }
            return result
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func findOffSpaceWindow(_ key: WindowKey, getID: GetID) -> AXUIElement? {
        // AXWindows can omit windows on other Spaces. Resolve the exact window root through its AX token.
        guard let createFromToken, let token = CFDataCreateMutable(nil, 20) else { return nil }
        CFDataSetLength(token, 20)
        guard let bytes = CFDataGetMutableBytePtr(token) else { return nil }
        let buffer = UnsafeMutableRawBufferPointer(start: bytes, count: 20)
        buffer.storeBytes(of: key.pid, toByteOffset: 0, as: pid_t.self)
        buffer.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
        buffer.storeBytes(of: UInt32(0x636f636f), toByteOffset: 8, as: UInt32.self)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        var elementID: UInt64 = 0
        while !Task.isCancelled, ContinuousClock.now < deadline {
            withUnsafeBytes(of: &elementID) { tokenID in
                buffer[12..<20].copyBytes(from: tokenID)
            }
            elementID += 1
            guard let element = createFromToken(token)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.05)
            guard windowID(element, getID) == key.id else { continue }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
               role as? String == kAXWindowRole {
                return element
            }
        }
        return nil
    }

    private static func remember(_ window: AXUIElement, for key: WindowKey) {
        knownWindows.withLock { windows in
            if windows[key] == nil, windows.count >= 32, let oldest = windows.keys.first {
                windows.removeValue(forKey: oldest)
            }
            windows[key] = WindowHandle(element: window)
        }
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
        let window = unsafeDowncast(value, to: AXUIElement.self)
        guard let id = windowID(window, getID) else { return nil }
        remember(window, for: WindowKey(pid: pid, id: id))
        return id
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

    private static let createFromToken: CreateFromToken? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let framework = dlopen(path, RTLD_LAZY),
              let address = dlsym(framework, "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(address, to: CreateFromToken.self)
    }()

    private static func windowID(_ element: AXUIElement, _ getID: GetID) -> CGWindowID? {
        var id: CGWindowID = 0
        return getID(element, &id) == .success ? id : nil
    }
}
