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

/// A named profile owns one independently configurable shelf projection.
///
/// `id` is the durable identity used by workspace/profile UI and future window
/// membership state. `name` is presentation-only and can change without moving
/// windows between profiles.
public struct WorkspaceProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var shelfConfig: ShelfConfig
    /// Live window identities currently owned by this profile. Window identity is
    /// intentionally live-session scoped (`WindowKey` string), not a guessed
    /// durable document identity.
    public var windowKeys: [String]

    public init(id: String, name: String, shelfConfig: ShelfConfig, windowKeys: [String] = []) {
        self.id = id
        self.name = name
        self.shelfConfig = shelfConfig
        self.windowKeys = windowKeys
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case shelfConfig
        case windowKeys
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        shelfConfig = try values.decode(ShelfConfig.self, forKey: .shelfConfig)
        windowKeys = try values.decodeIfPresent([String].self, forKey: .windowKeys) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        let validated = try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(validated.id, forKey: .id)
        try values.encode(validated.name, forKey: .name)
        try values.encode(validated.shelfConfig, forKey: .shelfConfig)
        try values.encode(validated.windowKeys, forKey: .windowKeys)
    }

    public func validated() throws -> WorkspaceProfile {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw WorkspaceConfigValidationError.emptyProfileID
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspaceProfile(
            id: normalizedID,
            name: normalizedName.isEmpty ? normalizedID : normalizedName,
            shelfConfig: try shelfConfig.validated(),
            windowKeys: Self.normalizedWindowKeys(windowKeys)
        )
    }

    private static func normalizedWindowKeys(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty {
            guard WindowKey(stringValue: value) != nil, seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }
}

public struct WorkspaceHotKeyConfig: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var previous: KeyboardShortcut
    public var next: KeyboardShortcut

    public init(
        isEnabled: Bool = true,
        previous: KeyboardShortcut = .defaultPreviousProfileWindow,
        next: KeyboardShortcut = .defaultNextProfileWindow
    ) {
        self.isEnabled = isEnabled
        self.previous = previous
        self.next = next
    }

    public static let `default` = WorkspaceHotKeyConfig()
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifierFlags: UInt32

    public init(keyCode: UInt32, modifierFlags: UInt32) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    public static let defaultPreviousProfileWindow = KeyboardShortcut(keyCode: 123, modifierFlags: 0x1100)
    public static let defaultNextProfileWindow = KeyboardShortcut(keyCode: 124, modifierFlags: 0x1100)
}

public struct WorkspaceLoginItemConfig: Codable, Equatable, Sendable {
    public var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public static let `default` = WorkspaceLoginItemConfig()
}

public enum WorkspaceThemePreference: String, Codable, Sendable {
    case system
    case light
    case dark
}

public struct WorkspaceBehaviorConfig: Codable, Equatable, Sendable {
    public var minimizeOnRepeatClick: Bool
    public var optionTabSwitcherEnabled: Bool
    public var dockWindowTilesEnabled: Bool

    public init(
        minimizeOnRepeatClick: Bool = true,
        optionTabSwitcherEnabled: Bool = true,
        dockWindowTilesEnabled: Bool = true
    ) {
        self.minimizeOnRepeatClick = minimizeOnRepeatClick
        self.optionTabSwitcherEnabled = optionTabSwitcherEnabled
        self.dockWindowTilesEnabled = dockWindowTilesEnabled
    }

    public static let `default` = WorkspaceBehaviorConfig()

    private enum CodingKeys: String, CodingKey {
        case minimizeOnRepeatClick
        case optionTabSwitcherEnabled
        case dockWindowTilesEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        minimizeOnRepeatClick = try values.decodeIfPresent(Bool.self, forKey: .minimizeOnRepeatClick) ?? true
        optionTabSwitcherEnabled = try values.decodeIfPresent(Bool.self, forKey: .optionTabSwitcherEnabled) ?? true
        dockWindowTilesEnabled = try values.decodeIfPresent(Bool.self, forKey: .dockWindowTilesEnabled) ?? true
    }
}

public struct WorkspaceAppearanceConfig: Codable, Equatable, Sendable {
    public var theme: WorkspaceThemePreference

    public init(theme: WorkspaceThemePreference = .system) {
        self.theme = theme
    }

    public static let `default` = WorkspaceAppearanceConfig()
}

public struct WorkspaceUpdateConfig: Codable, Equatable, Sendable {
    public var channel: String
    public var releasesAPIURL: URL
    public var sparkleAppcastURL: URL
    public var automaticallyChecksForUpdates: Bool

    public init(
        channel: String = "preview",
        releasesAPIURL: URL = URL(string: "https://api.github.com/repos/DurkaEbanaya/WindowsWindows/releases")!,
        sparkleAppcastURL: URL = URL(string: "https://durkaebanaya.github.io/WindowsWindows/appcast.xml")!,
        automaticallyChecksForUpdates: Bool = true
    ) {
        self.channel = channel
        self.releasesAPIURL = releasesAPIURL
        self.sparkleAppcastURL = sparkleAppcastURL
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    public static let `default` = WorkspaceUpdateConfig()

    private enum CodingKeys: String, CodingKey {
        case channel
        case releasesAPIURL
        case sparkleAppcastURL
        case automaticallyChecksForUpdates
        case feedURL
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        channel = try values.decodeIfPresent(String.self, forKey: .channel) ?? "preview"
        releasesAPIURL = try values.decodeIfPresent(URL.self, forKey: .releasesAPIURL)
            ?? URL(string: "https://api.github.com/repos/DurkaEbanaya/WindowsWindows/releases")!
        sparkleAppcastURL = try values.decodeIfPresent(URL.self, forKey: .sparkleAppcastURL)
            ?? values.decodeIfPresent(URL.self, forKey: .feedURL)
            ?? URL(string: "https://durkaebanaya.github.io/WindowsWindows/appcast.xml")!
        automaticallyChecksForUpdates = try values.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyChecksForUpdates
        ) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(channel, forKey: .channel)
        try values.encode(releasesAPIURL, forKey: .releasesAPIURL)
        try values.encode(sparkleAppcastURL, forKey: .sparkleAppcastURL)
        try values.encode(automaticallyChecksForUpdates, forKey: .automaticallyChecksForUpdates)
    }
}

/// Durable user intent for profiles/workspaces.
///
/// Stored in the existing `config.json` path so migration is atomic and there is
/// a single source of truth. Current runtime code consumes `effectiveShelfConfig`
/// while profile-aware UI can edit the full document without inventing state from
/// generated proxy bundles or live Dock ordering.
public struct WorkspaceConfig: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3
    public static let defaultProfileID = "default"

    public var activeProfileID: String
    public var profiles: [WorkspaceProfile]
    public var hotKeys: WorkspaceHotKeyConfig
    public var loginItem: WorkspaceLoginItemConfig
    public var updates: WorkspaceUpdateConfig
    public var behavior: WorkspaceBehaviorConfig
    public var appearance: WorkspaceAppearanceConfig

    public init(
        activeProfileID: String = Self.defaultProfileID,
        profiles: [WorkspaceProfile] = [
            WorkspaceProfile(id: Self.defaultProfileID, name: "Default", shelfConfig: .default)
        ],
        hotKeys: WorkspaceHotKeyConfig = .default,
        loginItem: WorkspaceLoginItemConfig = .default,
        updates: WorkspaceUpdateConfig = .default,
        behavior: WorkspaceBehaviorConfig = .default,
        appearance: WorkspaceAppearanceConfig = .default
    ) {
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.hotKeys = hotKeys
        self.loginItem = loginItem
        self.updates = updates
        self.behavior = behavior
        self.appearance = appearance
    }

    public static let `default` = WorkspaceConfig()

    public var effectiveShelfConfig: ShelfConfig {
        profiles.first { $0.id == activeProfileID }?.shelfConfig ?? .default
    }

    public mutating func updateActiveShelfConfig(_ transform: (inout ShelfConfig) throws -> Void) throws {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else {
            throw WorkspaceConfigValidationError.activeProfileMissing(activeProfileID)
        }
        try transform(&profiles[index].shelfConfig)
        profiles[index].shelfConfig = try profiles[index].shelfConfig.validated()
    }

    public var activeProfile: WorkspaceProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    public func activeWindowKeySet() -> Set<WindowKey> {
        Set((activeProfile?.windowKeys ?? []).compactMap(WindowKey.init(stringValue:)))
    }

    @discardableResult
    public mutating func assignNewWindowsToActiveProfile(_ keys: Set<WindowKey>) throws -> Bool {
        guard let activeIndex = profiles.firstIndex(where: { $0.id == activeProfileID }) else {
            throw WorkspaceConfigValidationError.activeProfileMissing(activeProfileID)
        }
        let originalProfiles = profiles
        let liveStrings = Set(keys.map(\.stringValue))
        var assignedElsewhere = Set<String>()
        for index in profiles.indices where index != activeIndex {
            profiles[index].windowKeys = profiles[index].windowKeys.filter { liveStrings.contains($0) }
            assignedElsewhere.formUnion(profiles[index].windowKeys)
        }

        var activeKeys = profiles[activeIndex].windowKeys.filter { liveStrings.contains($0) }
        var activeSet = Set(activeKeys)
        for key in keys.map(\.stringValue).sorted() where !activeSet.contains(key) && !assignedElsewhere.contains(key) {
            activeKeys.append(key)
            activeSet.insert(key)
        }
        profiles[activeIndex].windowKeys = activeKeys
        self = try validated()
        let changed = originalProfiles.map(\.windowKeys) != profiles.map(\.windowKeys)
        return changed
    }

    public mutating func moveWindow(_ key: WindowKey, toProfileID profileID: String) throws {
        let keyString = key.stringValue
        guard profiles.contains(where: { $0.id == profileID }) else {
            throw WorkspaceConfigValidationError.activeProfileMissing(profileID)
        }
        for index in profiles.indices {
            profiles[index].windowKeys.removeAll { $0 == keyString }
        }
        guard let target = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[target].windowKeys.append(keyString)
        self = try validated()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case activeProfileID
        case profiles
        case hotKeys
        case loginItem
        case updates
        case behavior
        case appearance
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion: Int
        if values.contains(.schemaVersion) {
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        } else {
            schemaVersion = 1
        }

        switch schemaVersion {
        case 1, ShelfConfig.currentSchemaVersion:
            let legacy = try ShelfConfig(from: decoder).validated()
            self = WorkspaceConfig(profiles: [
                WorkspaceProfile(id: Self.defaultProfileID, name: "Default", shelfConfig: legacy)
            ])
        case Self.currentSchemaVersion:
            activeProfileID = try values.decode(String.self, forKey: .activeProfileID)
            profiles = try values.decode([WorkspaceProfile].self, forKey: .profiles)
            hotKeys = try values.decodeIfPresent(WorkspaceHotKeyConfig.self, forKey: .hotKeys) ?? .default
            loginItem = try values.decodeIfPresent(WorkspaceLoginItemConfig.self, forKey: .loginItem) ?? .default
            updates = try values.decodeIfPresent(WorkspaceUpdateConfig.self, forKey: .updates) ?? .default
            behavior = try values.decodeIfPresent(WorkspaceBehaviorConfig.self, forKey: .behavior) ?? .default
            appearance = try values.decodeIfPresent(WorkspaceAppearanceConfig.self, forKey: .appearance) ?? .default
            self = try validated()
        default:
            throw ShelfConfigSchemaError.unsupportedVersion(schemaVersion)
        }
    }

    public func encode(to encoder: Encoder) throws {
        let validated = try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(validated.activeProfileID, forKey: .activeProfileID)
        try values.encode(validated.profiles, forKey: .profiles)
        try values.encode(validated.hotKeys, forKey: .hotKeys)
        try values.encode(validated.loginItem, forKey: .loginItem)
        try values.encode(validated.updates, forKey: .updates)
        try values.encode(validated.behavior, forKey: .behavior)
        try values.encode(validated.appearance, forKey: .appearance)
    }

    public func validated() throws -> WorkspaceConfig {
        let normalizedActiveID = activeProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedActiveID.isEmpty else {
            throw WorkspaceConfigValidationError.emptyActiveProfileID
        }

        var seen = Set<String>()
        let normalizedProfiles = try profiles.map { profile in
            let normalized = try profile.validated()
            guard seen.insert(normalized.id).inserted else {
                throw WorkspaceConfigValidationError.duplicateProfileID(normalized.id)
            }
            return normalized
        }
        guard !normalizedProfiles.isEmpty else {
            throw WorkspaceConfigValidationError.noProfiles
        }
        guard normalizedProfiles.contains(where: { $0.id == normalizedActiveID }) else {
            throw WorkspaceConfigValidationError.activeProfileMissing(normalizedActiveID)
        }

        return WorkspaceConfig(
            activeProfileID: normalizedActiveID,
            profiles: normalizedProfiles,
            hotKeys: hotKeys,
            loginItem: loginItem,
            updates: updates,
            behavior: behavior,
            appearance: appearance
        )
    }
}

public enum WorkspaceConfigValidationError: LocalizedError, Equatable {
    case emptyActiveProfileID
    case emptyProfileID
    case duplicateProfileID(String)
    case activeProfileMissing(String)
    case noProfiles

    public var errorDescription: String? {
        switch self {
        case .emptyActiveProfileID:
            return "activeProfileID must not be empty"
        case .emptyProfileID:
            return "profile id must not be empty"
        case .duplicateProfileID(let id):
            return "duplicate profile id: \(id)"
        case .activeProfileMissing(let id):
            return "active profile does not exist: \(id)"
        case .noProfiles:
            return "workspace must contain at least one profile"
        }
    }
}
