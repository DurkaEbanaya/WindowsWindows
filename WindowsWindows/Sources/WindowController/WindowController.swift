import Foundation
import Cocoa
import ApplicationServices

/// Управление реальным окном: фокус, raise, minimize, toggle.
///
/// Поведение toggle (по клику на прокси):
/// - Окно в фокусе и на переднем плане → минимизировать.
/// - Окно минимизировано → восстановить + фокус.
/// - Окно не в фокусе, но видимо → фокус + raise.
/// - Окно скрыто (app hidden) → unhide app + фокус.
public final class WindowController {

    /// Дебаунс: один windowKey не чаще чем раз в N мс,
    /// иначе двойные срабатывания (Dock может слать несколько активаций).
    private static let debounceInterval: TimeInterval = 0.25

    private var lastToggleTimes: [WindowKey: Date] = [:]
    private let queue = DispatchQueue(label: "com.windowswindows.windowcontroller")

    private let resolver: AXWindowIDResolver

    public init(resolver: AXWindowIDResolver = .shared) {
        self.resolver = resolver
    }

    /// Toggle окна: фокус/минимизация в зависимости от текущего состояния.
    ///
    /// - Parameter window: целевое окно (с актуальным axWindow handle).
    public func toggle(window: ObservedWindow, wasFocusedBeforeProxy: Bool) {
        let key = window.key
        // Дебаунс.
        let now = Date()
        let shouldProcess: Bool = queue.sync {
            if let last = lastToggleTimes[key], now.timeIntervalSince(last) < Self.debounceInterval {
                return false
            }
            lastToggleTimes[key] = now
            return true
        }
        guard shouldProcess else {
            DiagnosticJournal.shared.log("window_control", "toggle_debounced", fields: [
                "key": key.stringValue
            ])
            return
        }

        guard let ax = window.axWindow else {
            DiagnosticJournal.shared.log("window_control", "missing_ax_handle", fields: [
                "key": key.stringValue
            ])
            return
        }

        let isMinimized = readMinimized(ax: ax) ?? false

        DiagnosticJournal.shared.log("window_control", "toggle", fields: [
            "key": key.stringValue,
            "title": window.title,
            "targetFocusedBeforeProxy": wasFocusedBeforeProxy,
            "minimized": isMinimized,
            "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        ])

        if isMinimized {
            // Восстановить + фокус.
            _ = setMinimized(false, on: ax)
            raiseAndActivate(window: window, ax: ax)
        } else if wasFocusedBeforeProxy {
            // Уже в фокусе → минимизировать.
            let result = setMinimized(true, on: ax)
            DiagnosticJournal.shared.log("window_control", "minimize", fields: [
                "key": key.stringValue,
                "axError": result.rawValue
            ])
        } else {
            // Видимо, но не в фокусе → фокус + raise.
            raiseAndActivate(window: window, ax: ax)
        }
    }

    /// Принудительно поднять окно (без toggle). Используется при refresh,
    /// если нужно синхронизировать состояние.
    public func raise(window: ObservedWindow) {
        guard let ax = window.axWindow else {
            DiagnosticJournal.shared.log("window_control", "raise_missing_ax", fields: [
                "key": window.key.stringValue
            ])
            return
        }
        if readMinimized(ax: ax) ?? false {
            _ = setMinimized(false, on: ax)
        }
        raiseAndActivate(window: window, ax: ax)
    }

    // MARK: - Internal

    private func readMinimized(ax: AXUIElement) -> Bool? {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &ref)
        guard r == .success else { return nil }
        return ref as? Bool
    }

    @discardableResult
    private func setMinimized(_ value: Bool, on ax: AXUIElement) -> AXError {
        let v: CFTypeRef? = value as CFTypeRef
        return AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, v as CFTypeRef)
    }

    private func raiseAndActivate(window: ObservedWindow, ax: AXUIElement) {
        // 1. Сначала активируем приложение целиком (чтобы оно стало frontmost).
        //    Без этого setAttribute(kAXMain=true) бесполезен.
        let activationSucceeded = activateApp(pid: window.appPID)

        // 2. Снять minimized, если окно свёрнуто.
        if readMinimized(ax: ax) == true {
            _ = setMinimized(false, on: ax)
        }

        // 3. AXRaise через performAction — это поднимает конкретное окно.
        let raiseAction = "AXRaise" as CFString
        let firstRaise = AXUIElementPerformAction(ax, raiseAction)

        // 4. Поставить окно как main+frontmost — это делает его key-window
        //    в приложении (после того как приложение frontmost).
        let mainVal: CFTypeRef = kCFBooleanTrue
        let setMain = AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, mainVal)
        let frontVal: CFTypeRef = kCFBooleanTrue
        let setFrontmost = AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, frontVal)

        let appElement = AXUIElementCreateApplication(window.appPID)
        let setFocused = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            ax
        )

        // 5. Повторная активация (после raise) для надёжности.
        let secondActivation = activateApp(pid: window.appPID)
        let secondRaise = AXUIElementPerformAction(ax, raiseAction)
        let actualFocusedID = focusedWindowID(pid: window.appPID)

        DiagnosticJournal.shared.log("window_control", "raise_sequence", fields: [
            "key": window.key.stringValue,
            "expectedWindowID": window.windowNumber,
            "actualFocusedWindowID": actualFocusedID ?? 0,
            "firstActivation": activationSucceeded,
            "firstRaise": firstRaise.rawValue,
            "setMain": setMain.rawValue,
            "setFrontmost": setFrontmost.rawValue,
            "setFocused": setFocused.rawValue,
            "secondActivation": secondActivation,
            "secondRaise": secondRaise.rawValue
        ])
    }

    private func focusedWindowID(pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
              let focused = value as! AXUIElement? else {
            return nil
        }
        return resolver.windowID(for: focused)
    }

    @discardableResult
    private func activateApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        // unhide если скрыто, затем активировать.
        app.unhide()
        // macOS 14+: activate(options:) deprecated → activate()
        if #available(macOS 14.0, *) {
            return app.activate()
        } else {
            return app.activate(options: [.activateAllWindows])
        }
    }
}
