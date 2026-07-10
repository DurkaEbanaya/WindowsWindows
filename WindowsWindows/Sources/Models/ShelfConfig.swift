import Foundation

/// Конфигурация WindowsWindows.
///
/// Хранится в `~/Library/Application Support/WindowsWindows/config.json`.
/// Системные приложения (Dock, System Settings, Finder, LoginWindow и т.д.)
/// исключаются всегда через `Policy.systemExclusions` — это baseline, который
/// пользователь не может переопределить через конфиг (защита от случайной
/// регистрации прокси для системных UI-процессов, что приведёт к зацикливанию
/// и визуальному мусору).
public struct ShelfConfig: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let minimumRefreshInterval: TimeInterval = 0.25
    public static let maximumRefreshInterval: TimeInterval = 3_600
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

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case scopeMode
        case bundleIdentifiers
        case refreshInterval
        case snapshotInterval
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion: Int
        if values.contains(.schemaVersion) {
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        } else {
            schemaVersion = 1
        }
        guard schemaVersion == 1 || schemaVersion == Self.currentSchemaVersion else {
            throw ShelfConfigSchemaError.unsupportedVersion(schemaVersion)
        }

        scopeMode = try values.decode(ScopeMode.self, forKey: .scopeMode)
        bundleIdentifiers = try values.decode([String].self, forKey: .bundleIdentifiers)
        refreshInterval = try values.decode(TimeInterval.self, forKey: .refreshInterval)
        snapshotInterval = try values.decode(TimeInterval.self, forKey: .snapshotInterval)

        if schemaVersion == 1 {
            migrateFromVersion1()
        }
        self = try validated()
    }

    public func encode(to encoder: Encoder) throws {
        let validated = try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(validated.scopeMode, forKey: .scopeMode)
        try values.encode(validated.bundleIdentifiers, forKey: .bundleIdentifiers)
        try values.encode(validated.refreshInterval, forKey: .refreshInterval)
        try values.encode(validated.snapshotInterval, forKey: .snapshotInterval)
    }

    private mutating func migrateFromVersion1() {
        guard refreshInterval.isFinite, snapshotInterval.isFinite else { return }
        refreshInterval = min(
            max(refreshInterval, Self.minimumRefreshInterval),
            Self.maximumRefreshInterval
        )
        snapshotInterval = min(
            max(snapshotInterval, refreshInterval),
            Self.maximumRefreshInterval
        )
    }

    public func validated() throws -> ShelfConfig {
        guard refreshInterval.isFinite,
              refreshInterval >= Self.minimumRefreshInterval,
              refreshInterval <= Self.maximumRefreshInterval else {
            throw ShelfConfigValidationError.invalidRefreshInterval(refreshInterval)
        }
        guard snapshotInterval.isFinite,
              snapshotInterval >= refreshInterval,
              snapshotInterval <= Self.maximumRefreshInterval else {
            throw ShelfConfigValidationError.invalidSnapshotInterval(
                snapshotInterval,
                minimum: refreshInterval
            )
        }
        let normalizedIDs = Array(
            Set(bundleIdentifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        ).filter { !$0.isEmpty }.sorted()
        return ShelfConfig(
            scopeMode: scopeMode,
            bundleIdentifiers: normalizedIDs,
            refreshInterval: refreshInterval,
            snapshotInterval: snapshotInterval
        )
    }
}

public enum ShelfConfigSchemaError: LocalizedError, Equatable {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "unsupported config schema version: \(version)"
        }
    }
}

public enum ShelfConfigValidationError: LocalizedError, Equatable {
    case invalidRefreshInterval(TimeInterval)
    case invalidSnapshotInterval(TimeInterval, minimum: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .invalidRefreshInterval(let value):
            return "refreshInterval must be finite and between \(ShelfConfig.minimumRefreshInterval) and \(ShelfConfig.maximumRefreshInterval) seconds; got \(value)"
        case .invalidSnapshotInterval(let value, let minimum):
            return "snapshotInterval must be finite and between refreshInterval (\(minimum)) and \(ShelfConfig.maximumRefreshInterval) seconds; got \(value)"
        }
    }
}
