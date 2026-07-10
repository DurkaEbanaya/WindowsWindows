import Foundation

/// Конфигурация WindowsWindows.
///
/// Хранится в `~/Library/Application Support/WindowsWindows/config.json`.
/// Системные приложения (Dock, System Settings, Finder, LoginWindow и т.д.)
/// исключаются всегда через `Policy.systemExclusions` — это baseline, который
/// пользователь не может переопределить через конфиг (защита от случайной
/// регистрации прокси для системных UI-процессов, что приведёт к зацикливанию
/// и визуальному мусору).
public struct ShelfConfig: Codable, Sendable {
    public var scopeMode: ScopeMode
    public var bundleIdentifiers: [String]
    /// Интервал обновления состояния, секунд.
    public var refreshInterval: TimeInterval
    /// Интервал обновления превью (снапшотов), секунд. Должен быть >= refreshInterval.
    public var snapshotInterval: TimeInterval

    public init(
        scopeMode: ScopeMode = .allExceptListed,
        bundleIdentifiers: [String] = [],
        refreshInterval: TimeInterval = 2.0,
        snapshotInterval: TimeInterval = 5.0
    ) {
        self.scopeMode = scopeMode
        self.bundleIdentifiers = bundleIdentifiers
        self.refreshInterval = refreshInterval
        self.snapshotInterval = snapshotInterval
    }

    public static let `default` = ShelfConfig()
}
