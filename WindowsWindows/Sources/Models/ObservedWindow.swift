import Foundation
import ApplicationServices
import Darwin

public struct ProcessIdentity: Hashable, Sendable {
    public let processIdentifier: pid_t
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init?(
        processIdentifier: pid_t,
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt64
    ) {
        guard processIdentifier > 0 else { return nil }
        self.processIdentifier = processIdentifier
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }

    public static func live(processIdentifier: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard actualSize == expectedSize else { return nil }
        return ProcessIdentity(
            processIdentifier: processIdentifier,
            startTimeSeconds: UInt64(info.pbi_start_tvsec),
            startTimeMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    public var isLiveProcess: Bool {
        Self.live(processIdentifier: processIdentifier) == self
    }
}

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
    public let processIdentity: ProcessIdentity
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
        processIdentity: ProcessIdentity,
        windowNumber: CGWindowID,
        bundleIdentifier: String,
        appName: String,
        title: String,
        frame: CGRect,
        isMinimized: Bool,
        axWindow: AXUIElement? = nil
    ) {
        self.appPID = appPID
        self.processIdentity = processIdentity
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

/// Presentation metadata is deliberately separate from `WindowKey`: names can
/// change, while window identity must remain stable for IPC and lifecycle work.
public struct ProxyPresentation: Equatable, Sendable {
    public let appName: String
    public let windowTitle: String

    public init(appName: String, windowTitle: String) {
        self.appName = Self.normalized(appName).isEmpty ? "Application" : Self.normalized(appName)
        self.windowTitle = Self.normalized(windowTitle)
    }

    public var displayName: String {
        let fullName: String
        if windowTitle.isEmpty || windowTitle == appName {
            fullName = appName
        } else {
            fullName = "\(appName) — \(windowTitle)"
        }
        return Self.truncated(fullName, maximumCharacters: 80)
    }

    /// A readable path component only. It is never parsed as identity.
    public var bundlePathComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = appName.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let sanitized = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        let safeName = sanitized.isEmpty || sanitized == "." || sanitized == ".." ? "Application" : sanitized
        return Self.truncated(safeName, maximumCharacters: 48)
    }

    private static func normalized(_ value: String) -> String {
        let printable = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(printable)).components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func truncated(_ value: String, maximumCharacters: Int) -> String {
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters - 1)) + "…"
    }
}
