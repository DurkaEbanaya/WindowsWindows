import Foundation
import ApplicationServices

/// Одно отслеживаемое окно чужого приложения.
///
/// Identity: `(appPID, windowNumber)` — стабильно на времени жизни окна.
/// `axWindow` хранится отдельно и может пересоздаваться при refresh.
/// `title` и `bounds` — display-only, не входят в identity.
// AXUIElement is an immutable CoreFoundation handle. The referenced remote UI
// object may change, but the handle itself can be passed between executor
// domains and all access still goes through thread-safe AX functions.
public struct ObservedWindow: Hashable, Identifiable, @unchecked Sendable {
    public let appPID: pid_t
    public let windowNumber: CGWindowID
    public var bundleIdentifier: String
    public var appName: String
    public var title: String
    public var frame: CGRect
    public var isMinimized: Bool
    public var axWindow: AXUIElement?

    /// Стабильный ключ, переживает refresh. Не зависит от AXUIElement / title.
    public var key: WindowKey {
        WindowKey(appPID: appPID, windowNumber: windowNumber)
    }

    public var id: WindowKey { key }

    public init(
        appPID: pid_t,
        windowNumber: CGWindowID,
        bundleIdentifier: String,
        appName: String,
        title: String,
        frame: CGRect,
        isMinimized: Bool,
        axWindow: AXUIElement? = nil
    ) {
        self.appPID = appPID
        self.windowNumber = windowNumber
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.axWindow = axWindow
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(appPID)
        hasher.combine(windowNumber)
    }

    public static func == (lhs: ObservedWindow, rhs: ObservedWindow) -> Bool {
        lhs.appPID == rhs.appPID && lhs.windowNumber == rhs.windowNumber
    }
}

/// Стабильный идентификатор окна, используемый в IPC и в именах proxy-бандлов.
public struct WindowKey: Hashable, Codable, Sendable {
    public let appPID: pid_t
    public let windowNumber: CGWindowID

    public init(appPID: pid_t, windowNumber: CGWindowID) {
        self.appPID = appPID
        self.windowNumber = windowNumber
    }

    /// Строковое представление для имен файлов прокси-бандлов и IPC.
    /// Формат: `pid-<pid>-wid-<wid>` — filename-safe, deterministic.
    public var stringValue: String {
        "pid-\(appPID)-wid-\(windowNumber)"
    }

    public init?(stringValue: String) {
        // pattern: pid-<int>-wid-<int>
        let parts = stringValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "pid",
              parts[2] == "wid",
              let pid = pid_t(parts[1]),
              let wid = CGWindowID(parts[3])
        else { return nil }
        self.appPID = pid
        self.windowNumber = wid
    }
}
