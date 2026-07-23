import Cocoa
import ApplicationServices

/// Tracks the focused window while a real application is active.
/// Reading AXFocusedWindow after deactivation is inherently racy, so focus is
/// observed while valid and preserved while a proxy briefly owns activation.
@MainActor
public final class WindowFocusTracker {
    private let resolver: AXWindowIDResolver
    private var focusedWindow: WindowKey?
    private var isStarted = false
    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private var onFocusedWindowChanged: ((WindowKey) -> Void)?
    private var onWindowMinimized: ((WindowKey) -> Void)?
    private var onWindowRestored: ((WindowKey) -> Void)?

    public init(resolver: AXWindowIDResolver = .shared) {
        self.resolver = resolver
    }

    public func start(
        onFocusedWindowChanged: ((WindowKey) -> Void)? = nil,
        onWindowMinimized: ((WindowKey) -> Void)? = nil,
        onWindowRestored: ((WindowKey) -> Void)? = nil
    ) {
        guard !isStarted else { return }
        self.onFocusedWindowChanged = onFocusedWindowChanged
        self.onWindowMinimized = onWindowMinimized
        self.onWindowRestored = onWindowRestored
        isStarted = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            observe(application: frontmost)
        }
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        removeAXObserver()
        onFocusedWindowChanged = nil
        onWindowMinimized = nil
        onWindowRestored = nil
    }

    public func wasFocusedImmediatelyBeforeProxy(_ key: WindowKey) -> Bool {
        return focusedWindow == key
    }

    public func currentFocusedWindowKey() -> WindowKey? {
        focusedWindow
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else {
            return
        }
        if Policy.isProxyBundle(bundleID) {
            removeAXObserver()
            return
        }
        if bundleID == "com.windowswindows.app" {
            removeAXObserver()
            focusedWindow = nil
            return
        }
        observe(application: app)
    }

    private func observe(application: NSRunningApplication) {
        guard let bundleID = application.bundleIdentifier,
              !Policy.isProxyBundle(bundleID),
              bundleID != "com.windowswindows.app" else {
            return
        }

        removeAXObserver()
        focusedWindow = nil
        let pid = application.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var newObserver: AXObserver?
        observedPID = pid
        let createResult = AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            var eventPID: pid_t = 0
            let tracker = Unmanaged<WindowFocusTracker>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard AXUIElementGetPid(element, &eventPID) == .success else {
                    tracker.focusedWindow = nil
                    return
                }
                if notification as String == kAXWindowMiniaturizedNotification {
                    tracker.captureWindowStateChange(element, pid: eventPID, isMinimized: true)
                } else if notification as String == kAXWindowDeminiaturizedNotification {
                    tracker.captureWindowStateChange(element, pid: eventPID, isMinimized: false)
                } else {
                    tracker.captureFocusedWindow(pid: eventPID)
                }
            }
        }, &newObserver)

        if createResult == .success, let newObserver {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let addResult = AXObserverAddNotification(
                newObserver,
                appElement,
                kAXFocusedWindowChangedNotification as CFString,
                context
            )
            if addResult == .success {
                _ = AXObserverAddNotification(
                    newObserver,
                    appElement,
                    kAXWindowMiniaturizedNotification as CFString,
                    context
                )
                _ = AXObserverAddNotification(
                    newObserver,
                    appElement,
                    kAXWindowDeminiaturizedNotification as CFString,
                    context
                )
                axObserver = newObserver
                CFRunLoopAddSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(newObserver),
                    .commonModes
                )
                captureFocusedWindow(pid: pid)
                return
            }
        }
        removeAXObserver()
        focusedWindow = nil
    }

    private func captureFocusedWindow(pid: pid_t) {
        guard observedPID == pid else { return }
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )

        if result == .success,
           let focused = value as! AXUIElement?,
           let windowID = resolver.windowID(for: focused) {
            let key = WindowKey(appPID: pid, windowNumber: windowID)
            focusedWindow = key
            onFocusedWindowChanged?(key)

            DiagnosticJournal.shared.log("focus", "focused_window_observed", fields: [
                "pid": pid,
                "key": key.stringValue,
                "axError": result.rawValue
            ])
            return
        }
        focusedWindow = nil
        DiagnosticJournal.shared.log("focus", "focused_window_observed", fields: [
            "pid": pid,
            "key": "",
            "axError": result.rawValue
        ])
    }

    private func captureWindowStateChange(_ window: AXUIElement, pid: pid_t, isMinimized: Bool) {
        guard observedPID == pid, let windowID = resolver.windowID(for: window) else { return }
        let key = WindowKey(appPID: pid, windowNumber: windowID)
        if isMinimized {
            onWindowMinimized?(key)
        } else {
            onWindowRestored?(key)
        }
        DiagnosticJournal.shared.log("focus", isMinimized ? "window_minimized_observed" : "window_restored_observed", fields: [
            "pid": pid,
            "key": key.stringValue
        ])
    }

    private func removeAXObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(axObserver),
                .commonModes
            )
        }
        axObserver = nil
        observedPID = nil
    }
}
