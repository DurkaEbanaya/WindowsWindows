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

    public init(resolver: AXWindowIDResolver = .shared) {
        self.resolver = resolver
    }

    public func start() {
        guard !isStarted else { return }
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
    }

    public func wasFocusedImmediatelyBeforeProxy(_ key: WindowKey) -> Bool {
        return focusedWindow == key
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
        let createResult = AXObserverCreate(pid, { _, element, _, context in
            guard let context else { return }
            var eventPID: pid_t = 0
            let tracker = Unmanaged<WindowFocusTracker>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard AXUIElementGetPid(element, &eventPID) == .success else {
                    tracker.focusedWindow = nil
                    return
                }
                tracker.captureFocusedWindow(pid: eventPID)
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
