import Cocoa
import ApplicationServices
import CoreGraphics

public enum DockPrimaryClickDecision: Equatable, Sendable {
    case useSystemBehavior
    case toggleExactWindow

    public static func decide(
        isEnabled: Bool,
        hasExactWindow: Bool,
        isProxyApplication: Bool
    ) -> DockPrimaryClickDecision {
        guard isEnabled, hasExactWindow, !isProxyApplication else {
            return .useSystemBehavior
        }
        return .toggleExactWindow
    }
}

public struct DockWindowPreferenceState: Equatable, Sendable {
    private var recentKeys: [pid_t: WindowKey] = [:]
    private var pinnedKeys: [pid_t: WindowKey] = [:]
    private var minimizedQueues: [pid_t: [WindowKey]] = [:]
    private var userInteractionExpirations: [pid_t: Date] = [:]

    public init() {}

    public mutating func noteUserInteraction(
        with applicationPID: pid_t,
        now: Date,
        duration: TimeInterval = 0.75
    ) {
        userInteractionExpirations[applicationPID] = now.addingTimeInterval(duration)
    }

    @discardableResult
    public mutating func observeFocusedWindow(_ key: WindowKey, now: Date) -> Bool {
        if let pinned = pinnedKeys[key.appPID], pinned != key {
            guard let expiration = userInteractionExpirations[key.appPID], expiration >= now else {
                return false
            }
            pinnedKeys.removeValue(forKey: key.appPID)
        }
        userInteractionExpirations.removeValue(forKey: key.appPID)
        recentKeys[key.appPID] = key
        return true
    }

    public mutating func pin(_ key: WindowKey) {
        pinnedKeys[key.appPID] = key
        recentKeys[key.appPID] = key
    }

    public mutating func noteMinimized(_ key: WindowKey) {
        var queue = minimizedQueues[key.appPID] ?? []
        queue.removeAll { $0 == key }
        queue.append(key)
        minimizedQueues[key.appPID] = queue
        pin(key)
    }

    public mutating func noteRestored(_ key: WindowKey) {
        guard var queue = minimizedQueues[key.appPID] else { return }
        queue.removeAll { $0 == key }
        minimizedQueues[key.appPID] = queue.isEmpty ? nil : queue
    }

    public func targetKey(for applicationPID: pid_t) -> WindowKey? {
        let minimized = minimizedQueues[applicationPID] ?? []
        if minimized.count > 1 { return minimized[0] }
        return minimized.first ?? pinnedKeys[applicationPID] ?? recentKeys[applicationPID]
    }

    public mutating func invalidateTarget(for applicationPID: pid_t) {
        pinnedKeys.removeValue(forKey: applicationPID)
        recentKeys.removeValue(forKey: applicationPID)
        minimizedQueues.removeValue(forKey: applicationPID)
        userInteractionExpirations.removeValue(forKey: applicationPID)
    }
}

@MainActor
public final class DockRepeatClickController {
    private enum Target {
        case application(pid_t)
        case proxy(WindowKey)
    }

    private enum PendingAction {
        case toggle(pid_t)
        case quit(pid_t)
        case close(WindowKey)
    }

    private let systemWideElement = AXUIElementCreateSystemWide()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingLeftAction: PendingAction?
    private var pendingMiddleAction: PendingAction?
    private var canToggleHandler: ((NSRunningApplication) -> Bool)?
    private var toggleHandler: ((NSRunningApplication) -> Void)?
    private var closeProxyHandler: ((WindowKey) -> Void)?
    private var userInteractionHandler: ((pid_t) -> Void)?
    public var isPrimaryClickEnabled = true

    public init() {}

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    public func start(
        canToggle: @escaping (NSRunningApplication) -> Bool,
        toggle: @escaping (NSRunningApplication) -> Void,
        closeProxy: @escaping (WindowKey) -> Void,
        userInteraction: @escaping (pid_t) -> Void
    ) {
        stop()
        canToggleHandler = canToggle
        toggleHandler = toggle
        closeProxyHandler = closeProxy
        userInteractionHandler = userInteraction
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<DockRepeatClickController>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    controller.handle(type: type, event: event)
                        ? nil
                        : Unmanaged.passUnretained(event)
                }
            },
            userInfo: context
        ) else {
            DiagnosticJournal.shared.log("dock_click", "event_tap_registration_failed")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DiagnosticJournal.shared.log("dock_click", "event_tap_registered")
    }

    public func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        pendingLeftAction = nil
        pendingMiddleAction = nil
        canToggleHandler = nil
        toggleHandler = nil
        closeProxyHandler = nil
        userInteractionHandler = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pendingLeftAction = nil
            pendingMiddleAction = nil
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }

        switch type {
        case .leftMouseDown:
            guard let target = target(at: event.location) else {
                noteUserInteraction(at: event.location)
                return false
            }
            pendingLeftAction = primaryAction(for: target)
            return pendingLeftAction != nil
        case .leftMouseUp:
            guard let action = pendingLeftAction else { return false }
            pendingLeftAction = nil
            perform(action)
            return true
        case .otherMouseDown where event.getIntegerValueField(.mouseEventButtonNumber) == 2:
            pendingMiddleAction = middleAction(at: event.location)
            return pendingMiddleAction != nil
        case .otherMouseUp where event.getIntegerValueField(.mouseEventButtonNumber) == 2:
            guard let action = pendingMiddleAction else { return false }
            pendingMiddleAction = nil
            perform(action)
            return true
        case .keyDown:
            noteFrontmostUserInteraction()
            return false
        default:
            return false
        }
    }

    private func primaryAction(for target: Target) -> PendingAction? {
        guard case .application(let pid) = target,
              let application = NSRunningApplication(processIdentifier: pid),
              let bundleIdentifier = application.bundleIdentifier else { return nil }
        let hasExactWindow = canToggleHandler?(application) == true
        guard DockPrimaryClickDecision.decide(
            isEnabled: isPrimaryClickEnabled,
            hasExactWindow: hasExactWindow,
            isProxyApplication: Policy.isProxyBundle(bundleIdentifier)
        ) == .toggleExactWindow else { return nil }
        return .toggle(pid)
    }

    private func noteFrontmostUserInteraction() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        userInteractionHandler?(pid)
    }

    private func noteUserInteraction(at point: CGPoint) {
        var element: AXUIElement?
        var pid: pid_t = 0
        if AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &element) == .success,
           let element,
           AXUIElementGetPid(element, &pid) == .success,
           pid > 0 {
            userInteractionHandler?(pid)
        } else {
            noteFrontmostUserInteraction()
        }
    }

    private func middleAction(at point: CGPoint) -> PendingAction? {
        switch target(at: point) {
        case .application(let pid):
            return .quit(pid)
        case .proxy(let key):
            return .close(key)
        case nil:
            return nil
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .toggle(let pid):
            guard let application = NSRunningApplication(processIdentifier: pid) else { return }
            toggleHandler?(application)
        case .quit(let pid):
            guard let application = NSRunningApplication(processIdentifier: pid) else { return }
            let requested = application.terminate()
            DiagnosticJournal.shared.log("dock_click", "middle_quit", fields: [
                "pid": pid,
                "bundleID": application.bundleIdentifier ?? "",
                "requested": requested
            ])
        case .close(let key):
            closeProxyHandler?(key)
            DiagnosticJournal.shared.log("dock_click", "middle_close_window", fields: [
                "key": key.stringValue
            ])
        }
    }

    private func target(at point: CGPoint) -> Target? {
        guard let bundleURL = dockApplicationBundleURL(at: point),
              let bundle = Bundle(url: bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier else { return nil }
        if Policy.isProxyBundle(bundleIdentifier),
           let keyString = bundle.object(forInfoDictionaryKey: "WWWindowKey") as? String,
           let key = WindowKey(stringValue: keyString) {
            return .proxy(key)
        }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL }) else {
            return nil
        }
        return .application(application.processIdentifier)
    }

    private func dockApplicationBundleURL(at point: CGPoint) -> URL? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &element) == .success,
              var current = element else { return nil }

        for _ in 0..<5 {
            if readString(current, attribute: kAXSubroleAttribute) == kAXApplicationDockItemSubrole,
               let url = readURL(current) {
                return url
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef as! AXUIElement? else { return nil }
            current = parent
        }
        return nil
    }

    private func readString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func readURL(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}
