import Cocoa
import ApplicationServices

/// Tracks the exact real window that was focused immediately before Dock
/// activated a WindowsWindows proxy application.
///
/// A proxy becomes the frontmost app before its distributed click notification
/// reaches the main process, so querying `NSWorkspace.frontmostApplication` in
/// the click handler is too late. NSWorkspace sends didDeactivate for the real
/// app first; at that point its AXFocusedWindow still identifies the exact
/// window. We persist that WindowKey and use it as the toggle precondition.
public final class WindowFocusTracker {
    private let resolver: AXWindowIDResolver
    private let lock = NSLock()
    private var lastDeactivatedWindow: WindowKey?
    private var observers: [NSObjectProtocol] = []

    public init(resolver: AXWindowIDResolver = .shared) {
        self.resolver = resolver
    }

    public func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.captureDeactivatedApplication(notification)
        })
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    public func wasFocusedImmediatelyBeforeProxy(_ key: WindowKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastDeactivatedWindow == key
    }

    private func captureDeactivatedApplication(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              !Policy.isProxyBundle(bundleID),
              bundleID != "com.windowswindows.app" else {
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
              let focused = value as! AXUIElement?,
              let windowID = resolver.windowID(for: focused) else {
            DiagnosticJournal.shared.log("focus", "deactivation_without_focused_window", fields: [
                "pid": app.processIdentifier,
                "bundleID": bundleID
            ])
            return
        }

        let key = WindowKey(appPID: app.processIdentifier, windowNumber: windowID)
        lock.lock()
        lastDeactivatedWindow = key
        lock.unlock()
        DiagnosticJournal.shared.log("focus", "real_window_deactivated", fields: [
            "key": key.stringValue,
            "bundleID": bundleID
        ])
    }
}
