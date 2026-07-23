import Cocoa
import ApplicationServices

public enum DockItemTarget: Equatable, Sendable {
    case application(pid_t)
    case proxy(WindowKey)
}

@MainActor
public final class DockItemResolver {
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let dockOrientation: String
    private let dockEdgeWidth: CGFloat

    public init() {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        dockOrientation = defaults?.string(forKey: "orientation") ?? "bottom"
        dockEdgeWidth = max(
            CGFloat(defaults?.double(forKey: "tilesize") ?? 0),
            CGFloat(defaults?.double(forKey: "largesize") ?? 0),
            64
        ) + 24
    }

    public func isNearDock(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            let frame = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard frame.contains(point) else { return false }
            let localX = point.x - frame.minX
            let localY = point.y - frame.minY
            switch dockOrientation {
            case "left": return localX <= dockEdgeWidth
            case "right": return frame.width - localX <= dockEdgeWidth
            case "top": return localY <= dockEdgeWidth
            default: return frame.height - localY <= dockEdgeWidth
            }
        }
    }

    public func target(at point: CGPoint) -> DockItemTarget? {
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

    public func applicationPID(at point: CGPoint) -> pid_t? {
        var element: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &element) == .success,
              let element,
              AXUIElementGetPid(element, &pid) == .success,
              pid > 0 else { return nil }
        return pid
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
