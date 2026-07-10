import Foundation
import Cocoa
import ApplicationServices
import CoreGraphics
import Darwin

/// Exact bridge between Accessibility windows and WindowServer identities.
///
/// macOS does not expose a public `AXWindowNumber` attribute. The system
/// ApplicationServices binary does export `_AXUIElementGetWindow`, which maps
/// an AXUIElement directly to its CGWindowID. We resolve it dynamically and
/// fail closed if it disappears on a future macOS release: an unmatched AX
/// window is never attached to a proxy for a different window.
public final class AXWindowIDResolver: @unchecked Sendable {
    public static let shared = AXWindowIDResolver()

    private typealias Function = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private let function: Function?

    private init() {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            function = nil
            return
        }
        function = unsafeBitCast(symbol, to: Function.self)
    }

    public func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let function else { return nil }
        var id: CGWindowID = 0
        let result = function(element, &id)
        guard result == .success, id != 0 else { return nil }
        return id
    }

    public var isAvailable: Bool { function != nil }
}

/// Discovers user windows with an exact identity mapping:
/// AXUIElement -> `_AXUIElementGetWindow` -> CGWindowID.
///
/// AX is the source of the user-window set and control handle. CGWindowList is
/// used only to enrich the exact identity with WindowServer title and bounds.
/// There is no title/frame matching and therefore no ambiguity when multiple
/// windows share the same geometry or title.
/// Mutable discovery history is confined to the owning `RefreshLoop` actor.
public final class WindowDiscovery: @unchecked Sendable {
    private let resolver: AXWindowIDResolver
    private var loggedState: [WindowKey: String] = [:]

    public init(resolver: AXWindowIDResolver = .shared) {
        self.resolver = resolver
    }

    public func discover(config: ShelfConfig) -> [ObservedWindow] {
        guard resolver.isAvailable else {
            DiagnosticJournal.shared.log("discovery", "resolver_unavailable")
            return []
        }

        let cgByID = enumerateCGWindowsByID()
        var result: [ObservedWindow] = []
        var currentKeys: Set<WindowKey> = []

        for app in NSWorkspace.shared.runningApplications {
            let bundleID = app.bundleIdentifier ?? ""
            guard Policy.admit(bundleIdentifier: bundleID, config: config) else { continue }

            let pid = app.processIdentifier
            let appName = app.localizedName ?? bundleID
            let appElement = AXUIElementCreateApplication(pid)
            var windowsValue: CFTypeRef?
            let windowsResult = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsValue
            )
            guard windowsResult == .success,
                  let axWindows = windowsValue as? [AXUIElement] else {
                DiagnosticJournal.shared.log("discovery", "ax_windows_failed", fields: [
                    "pid": pid,
                    "bundleID": bundleID,
                    "axError": windowsResult.rawValue
                ])
                continue
            }

            for axWindow in axWindows {
                guard isUserWindow(axWindow) else { continue }
                guard let windowID = resolver.windowID(for: axWindow) else {
                    DiagnosticJournal.shared.log("discovery", "window_id_failed", fields: [
                        "pid": pid,
                        "bundleID": bundleID,
                        "axTitle": readString(axWindow, kAXTitleAttribute)
                    ])
                    continue
                }

                let cg = cgByID[windowID]
                let axTitle = readString(axWindow, kAXTitleAttribute)
                let cgTitle = (cg?[kCGWindowName as String] as? String) ?? ""
                let title = cgTitle.isEmpty ? axTitle : cgTitle
                let frame = parseBounds(cg?[kCGWindowBounds as String] as? [String: Any])
                let minimized = readBool(axWindow, kAXMinimizedAttribute) ?? false

                // WindowServer may omit minimized windows from some list modes;
                // the exact AX identity remains valid and is sufficient to keep
                // its tile alive and restore it.
                let observed = ObservedWindow(
                    appPID: pid,
                    windowNumber: windowID,
                    bundleIdentifier: bundleID,
                    appName: appName,
                    title: title,
                    frame: frame,
                    isMinimized: minimized,
                    axWindow: axWindow
                )
                result.append(observed)
                currentKeys.insert(observed.key)

                let state = "\(title)|\(minimized)|\(cg != nil)"
                if loggedState[observed.key] != state {
                    loggedState[observed.key] = state
                    DiagnosticJournal.shared.log("discovery", "window_bound", fields: [
                        "key": observed.key.stringValue,
                        "bundleID": bundleID,
                        "title": title,
                        "axTitle": axTitle,
                        "minimized": minimized,
                        "hasCGMetadata": cg != nil
                    ])
                }
            }
        }

        let removedKeys = Set(loggedState.keys).subtracting(currentKeys)
        for key in removedKeys {
            loggedState.removeValue(forKey: key)
            DiagnosticJournal.shared.log("discovery", "window_removed", fields: [
                "key": key.stringValue
            ])
        }

        return result
    }

    private func enumerateCGWindowsByID() -> [CGWindowID: [String: Any]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [CGWindowID: [String: Any]] = [:]
        for window in windows {
            guard let id = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            result[id] = window
        }
        return result
    }

    private func isUserWindow(_ window: AXUIElement) -> Bool {
        guard readString(window, kAXRoleAttribute) == "AXWindow" else { return false }
        let subrole = readString(window, kAXSubroleAttribute)
        return subrole.isEmpty || subrole == "AXStandardWindow" || subrole == "AXDialog"
    }

    private func readString(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private func readBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func parseBounds(_ dict: [String: Any]?) -> CGRect {
        guard let dict,
              let x = dict["X"] as? CGFloat,
              let y = dict["Y"] as? CGFloat,
              let width = dict["Width"] as? CGFloat,
              let height = dict["Height"] as? CGFloat else {
            return .null
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
