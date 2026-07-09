import Foundation

/// Режим области действия конфигурации.
public enum ScopeMode: String, Codable {
    /// Все приложения, кроме перечисленных в `bundleIdentifiers`.
    case allExceptListed
    /// Только приложения из `bundleIdentifiers`.
    case onlyListed
}

/// Одна запись в конфигурации приложений.
public struct ApplicationEntry: Codable, Hashable {
    public let bundleIdentifier: String

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }
}
