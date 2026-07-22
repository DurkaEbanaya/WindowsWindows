import Cocoa
import ApplicationServices
import CoreGraphics

public enum DockRepeatClickDecision: Equatable, Sendable {
    case ignore
    case minimize

    public static func decide(
        clickedApplicationPID: pid_t?,
        frontmostApplicationPID: pid_t?,
        isProxyApplication: Bool
    ) -> DockRepeatClickDecision {
        guard let clickedApplicationPID,
              clickedApplicationPID == frontmostApplicationPID,
              !isProxyApplication else {
            return .ignore
        }
        return .minimize
    }
}

@MainActor
public final class DockRepeatClickController {
    private let systemWideElement = AXUIElementCreateSystemWide()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var frontmostApplicationPIDAtMouseDown: pid_t?
    private var minimizeHandler: ((NSRunningApplication) -> Void)?

    public init() {}

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    public func start(minimize: @escaping (NSRunningApplication) -> Void) {
        stop()
        minimizeHandler = minimize
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<DockRepeatClickController>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { controller.handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            DiagnosticJournal.shared.log("dock_repeat_click", "event_tap_registration_failed")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
        frontmostApplicationPIDAtMouseDown = nil
        minimizeHandler = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            frontmostApplicationPIDAtMouseDown = nil
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        if type == .leftMouseDown {
            frontmostApplicationPIDAtMouseDown = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return
        }
        guard type == .leftMouseUp else { return }
        defer { frontmostApplicationPIDAtMouseDown = nil }
        guard let frontmostApplicationPIDAtMouseDown,
              let bundleURL = dockApplicationBundleURL(at: event.location),
              let application = NSRunningApplication(processIdentifier: frontmostApplicationPIDAtMouseDown),
              application.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL,
              let bundleIdentifier = application.bundleIdentifier else {
            return
        }
        guard DockRepeatClickDecision.decide(
            clickedApplicationPID: application.processIdentifier,
            frontmostApplicationPID: frontmostApplicationPIDAtMouseDown,
            isProxyApplication: Policy.isProxyBundle(bundleIdentifier)
        ) == .minimize else { return }
        minimizeHandler?(application)
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
