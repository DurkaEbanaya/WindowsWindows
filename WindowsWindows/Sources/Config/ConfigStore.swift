import Foundation
import Darwin

/// Загрузка/сохранение конфигурации в Application Support.
///
/// Layout:
/// ```
/// ~/Library/Application Support/WindowsWindows/
///   config.json
///   ProxyApps/                 <- генерируемые прокси-бандлы
/// ```
/// Instances are owned by `RefreshLoop` after startup. JSONEncoder/Decoder and
/// file access therefore remain confined to that actor.
public final class ConfigStore: @unchecked Sendable {
    public static let appName = "WindowsWindows"
    public static let proxyAppsDirName = "ProxyApps"

    public let supportURL: URL
    public let configURL: URL
    public let proxyAppsURL: URL
    public let lockURL: URL

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public convenience init() throws {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = base.appendingPathComponent(Self.appName, isDirectory: true)
        try self.init(supportURL: appDir)
    }

    public init(supportURL appDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.supportURL = appDir
        self.configURL = appDir.appendingPathComponent("config.json", isDirectory: false)
        self.proxyAppsURL = appDir.appendingPathComponent(Self.proxyAppsDirName, isDirectory: true)
        self.lockURL = appDir.appendingPathComponent("config.lock", isDirectory: false)
        try fm.createDirectory(at: proxyAppsURL, withIntermediateDirectories: true)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    /// Load and validate the full workspace document. Invalid user data is never
    /// silently overwritten: callers can keep the last known-good value and
    /// report the exact error instead of destroying the file that needs
    /// correction.
    public func loadWorkspace() throws -> WorkspaceConfig {
        try withExclusiveLock {
            guard fileManager.fileExists(atPath: configURL.path) else {
                let workspace = WorkspaceConfig.default
                try saveWorkspaceLocked(workspace)
                return workspace
            }
            let data = try Data(contentsOf: configURL)
            let workspace = try decoder.decode(WorkspaceConfig.self, from: data).validated()
            if try persistedSchemaVersion(in: data) != WorkspaceConfig.currentSchemaVersion {
                try saveWorkspaceLocked(workspace)
            }
            return workspace
        }
    }

    public func load() throws -> ShelfConfig {
        try loadWorkspace().effectiveShelfConfig
    }

    public func save(_ config: ShelfConfig) throws {
        try withExclusiveLock {
            var workspace = try loadWorkspaceLocked()
            try workspace.updateActiveShelfConfig { active in
                active = config
            }
            try saveWorkspaceLocked(workspace)
        }
    }

    public func saveWorkspace(_ workspace: WorkspaceConfig) throws {
        try withExclusiveLock {
            try saveWorkspaceLocked(workspace)
        }
    }

    /// Serialize a read-modify-write transaction across the app and `wwctl`.
    public func update(_ transform: (inout ShelfConfig) throws -> Void) throws -> ShelfConfig {
        try withExclusiveLock {
            var workspace = try loadWorkspaceLocked()
            try workspace.updateActiveShelfConfig(transform)
            let validated = try workspace.validated()
            try saveWorkspaceLocked(validated)
            return validated.effectiveShelfConfig
        }
    }

    public func updateWorkspace(_ transform: (inout WorkspaceConfig) throws -> Void) throws -> WorkspaceConfig {
        try withExclusiveLock {
            var workspace = try loadWorkspaceLocked()
            try transform(&workspace)
            let validated = try workspace.validated()
            try saveWorkspaceLocked(validated)
            return validated
        }
    }

    private func loadWorkspaceLocked() throws -> WorkspaceConfig {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return .default
        }
        let data = try Data(contentsOf: configURL)
        return try decoder.decode(WorkspaceConfig.self, from: data).validated()
    }

    private func saveWorkspaceLocked(_ workspace: WorkspaceConfig) throws {
        let validated = try workspace.validated()
        let data = try encoder.encode(validated)
        try data.write(to: configURL, options: [.atomic])
    }

    private func persistedSchemaVersion(in data: Data) throws -> Int? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let value = dictionary["schemaVersion"] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "schemaVersion must be an integer"
                )
            )
        }
        return number.intValue
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
