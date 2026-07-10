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
public struct WindowDiscoverySnapshot: @unchecked Sendable {
    public let windows: [ObservedWindow]
    /// Process lifetimes whose AX window set could not be observed completely. Consumers
    /// must not interpret an absent key from one of these applications as a
    /// closed window.
    public let incompleteApplications: Set<ProcessIdentity>
    /// PIDs admitted by policy but not attributable to a process lifetime.
    /// Consumers may retain state only after independently proving that its
    /// stored lifetime identity still matches the live process.
    public let unidentifiedApplicationPIDs: Set<pid_t>

    public init(
        windows: [ObservedWindow],
        incompleteApplications: Set<ProcessIdentity>,
        unidentifiedApplicationPIDs: Set<pid_t> = []
    ) {
        self.windows = windows
        self.incompleteApplications = incompleteApplications
        self.unidentifiedApplicationPIDs = unidentifiedApplicationPIDs
    }

    public func isAbsenceAuthoritative(
        for key: WindowKey,
        persistedProcessIdentity: ProcessIdentity?
    ) -> Bool {
        if let identity = persistedProcessIdentity {
            if incompleteApplications.contains(identity) { return false }
            if unidentifiedApplicationPIDs.contains(key.appPID),
               ProcessIdentity.live(processIdentifier: key.appPID) == identity {
                return false
            }
            return true
        }
        // v0.2 proxies have no lifetime metadata. Their ownership cannot be
        // reconstructed during an incomplete observation, so deletion must
        // wait for an authoritative pass for that PID.
        return !incompleteApplications.contains(where: { $0.processIdentifier == key.appPID })
            && !unidentifiedApplicationPIDs.contains(key.appPID)
    }
}

public final class WindowDiscovery: @unchecked Sendable {
    private let resolver: AXWindowIDResolver
    private var loggedState: [WindowKey: String] = [:]
    private var loggedFailureState: [pid_t: String] = [:]

    public init(resolver: AXWindowIDResolver = .shared) {
        self.resolver = resolver
    }

    public func discover(config: ShelfConfig) -> WindowDiscoverySnapshot {
        guard resolver.isAvailable else {
            DiagnosticJournal.shared.log("discovery", "resolver_unavailable")
            var admittedApplications: Set<ProcessIdentity> = []
            var unidentifiedPIDs: Set<pid_t> = []
            for app in NSWorkspace.shared.runningApplications
            where Policy.admit(bundleIdentifier: app.bundleIdentifier, config: config) {
                if let identity = ProcessIdentity.live(processIdentifier: app.processIdentifier) {
                    admittedApplications.insert(identity)
                } else {
                    unidentifiedPIDs.insert(app.processIdentifier)
                }
            }
            return WindowDiscoverySnapshot(
                windows: [],
                incompleteApplications: admittedApplications,
                unidentifiedApplicationPIDs: unidentifiedPIDs
            )
        }

        let cgByID = enumerateCGWindowsByID()
        var windowsByKey: [WindowKey: ObservedWindow] = [:]
        var currentKeys: Set<WindowKey> = []
        var incompleteApplications: Set<ProcessIdentity> = []
        var unidentifiedApplicationPIDs: Set<pid_t> = []
        var currentFailureState: [pid_t: Set<String>] = [:]

        for app in NSWorkspace.shared.runningApplications {
            let bundleID = app.bundleIdentifier ?? ""
            guard Policy.admit(bundleIdentifier: bundleID, config: config) else { continue }

            let pid = app.processIdentifier
            guard let processIdentity = ProcessIdentity.live(processIdentifier: pid) else {
                unidentifiedApplicationPIDs.insert(pid)
                currentFailureState[pid, default: []].insert("process-identity")
                continue
            }
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
                incompleteApplications.insert(processIdentity)
                currentFailureState[pid, default: []].insert("ax-windows:\(windowsResult.rawValue)")
                continue
            }

            var applicationWindows: [WindowKey: ObservedWindow] = [:]
            for axWindow in axWindows {
                switch classifyWindow(axWindow) {
                case .userWindow:
                    break
                case .ignored:
                    continue
                case .invalid(let role, let axError):
                    incompleteApplications.insert(processIdentity)
                    currentFailureState[pid, default: []].insert("invalid-element:\(role):\(axError)")
                    continue
                }
                guard let windowID = resolver.windowID(for: axWindow) else {
                    incompleteApplications.insert(processIdentity)
                    currentFailureState[pid, default: []].insert("window-id")
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
                    processIdentity: processIdentity,
                    windowNumber: windowID,
                    bundleIdentifier: bundleID,
                    appName: appName,
                    title: title,
                    frame: frame,
                    isMinimized: minimized,
                    axWindow: axWindow
                )
                guard applicationWindows[observed.key] == nil else {
                    incompleteApplications.insert(processIdentity)
                    currentFailureState[pid, default: []].insert("duplicate-key:\(observed.key.stringValue)")
                    continue
                }
                applicationWindows[observed.key] = observed

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

            guard ProcessIdentity.live(processIdentifier: pid) == processIdentity else {
                if let replacementIdentity = ProcessIdentity.live(processIdentifier: pid) {
                    incompleteApplications.insert(replacementIdentity)
                } else {
                    unidentifiedApplicationPIDs.insert(pid)
                }
                currentFailureState[pid, default: []].insert("process-lifetime-changed")
                continue
            }
            for (key, window) in applicationWindows {
                windowsByKey[key] = window
                currentKeys.insert(key)
            }
        }

        logFailureTransitions(currentFailureState)

        let removedKeys = Set(loggedState.keys).subtracting(currentKeys).filter {
            let currentIdentity = ProcessIdentity.live(processIdentifier: $0.appPID)
            return currentIdentity.map { !incompleteApplications.contains($0) } ?? true
        }
        for key in removedKeys {
            loggedState.removeValue(forKey: key)
            DiagnosticJournal.shared.log("discovery", "window_removed", fields: [
                "key": key.stringValue
            ])
        }

        return WindowDiscoverySnapshot(
            windows: Array(windowsByKey.values),
            incompleteApplications: incompleteApplications,
            unidentifiedApplicationPIDs: unidentifiedApplicationPIDs
        )
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

    private enum WindowClassification {
        case userWindow
        case ignored
        case invalid(role: String, axError: AXError.RawValue)
    }

    private func logFailureTransitions(_ currentState: [pid_t: Set<String>]) {
        let signatures = currentState.mapValues { $0.sorted().joined(separator: "|") }
        for (pid, signature) in signatures where loggedFailureState[pid] != signature {
            loggedFailureState[pid] = signature
            DiagnosticJournal.shared.log("discovery", "application_observation_incomplete", fields: [
                "pid": pid,
                "failures": signature
            ])
        }
        for pid in Set(loggedFailureState.keys).subtracting(signatures.keys) {
            loggedFailureState.removeValue(forKey: pid)
            DiagnosticJournal.shared.log("discovery", "application_observation_recovered", fields: [
                "pid": pid
            ])
        }
    }

    private func classifyWindow(_ window: AXUIElement) -> WindowClassification {
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            window,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else {
            return .invalid(role: "", axError: roleResult.rawValue)
        }
        // kAXWindowsAttribute is specified to contain window elements. A
        // different role means the upstream AX snapshot is structurally
        // invalid, not that the application has no user windows.
        guard role == kAXWindowRole else {
            return .invalid(role: role, axError: AXError.success.rawValue)
        }
        let subrole = readString(window, kAXSubroleAttribute)
        if subrole.isEmpty || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole {
            return .userWindow
        }
        return .ignored
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
