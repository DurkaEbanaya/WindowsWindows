import Foundation

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

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() throws {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = base.appendingPathComponent(Self.appName, isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.supportURL = appDir
        self.configURL = appDir.appendingPathComponent("config.json", isDirectory: false)
        self.proxyAppsURL = appDir.appendingPathComponent(Self.proxyAppsDirName, isDirectory: true)
        try fm.createDirectory(at: proxyAppsURL, withIntermediateDirectories: true)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    /// Загрузить конфиг. Если файл отсутствует или повреждён — вернуть default
    /// и сохранить его (чтобы пользователь мог увидеть/отредактировать структуру).
    public func load() throws -> ShelfConfig {
        guard fileManager.fileExists(atPath: configURL.path) else {
            let def = ShelfConfig.default
            try save(def)
            return def
        }
        do {
            let data = try Data(contentsOf: configURL)
            return try decoder.decode(ShelfConfig.self, from: data)
        } catch {
            // Повреждённый конфиг — не падаем, откатываемся к default.
            let def = ShelfConfig.default
            try save(def)
            return def
        }
    }

    public func save(_ config: ShelfConfig) throws {
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }
}
