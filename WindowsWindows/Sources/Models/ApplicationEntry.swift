import AppKit
import Foundation

/// Режим области действия конфигурации.
public enum ScopeMode: String, Codable, Sendable {
    /// Все приложения, кроме перечисленных в `bundleIdentifiers`.
    case allExceptListed
    /// Только приложения из `bundleIdentifiers`.
    case onlyListed
}

/// Одна запись в конфигурации приложений.
public struct ApplicationEntry: Codable, Hashable, Sendable {
    public let bundleIdentifier: String

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct ApplicationCatalogRow: Hashable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let isRunning: Bool

    public init(bundleIdentifier: String, name: String, isRunning: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.isRunning = isRunning
    }
}

public enum ApplicationCatalog {
    public static func load(configuredIDs: [String]) -> [ApplicationCatalogRow] {
        var rows: [String: ApplicationCatalogRow] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, Policy.isUserConfigurable(bundleIdentifier: id) else { continue }
            let name = app.localizedName ?? id
            rows[id] = ApplicationCatalogRow(bundleIdentifier: id, name: name, isRunning: true)
        }
        for id in configuredIDs where rows[id] == nil {
            rows[id] = ApplicationCatalogRow(
                bundleIdentifier: id,
                name: installedName(for: id) ?? id,
                isRunning: false
            )
        }
        return rows.values.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame
                ? $0.bundleIdentifier < $1.bundleIdentifier
                : comparison == .orderedAscending
        }
    }

    private static func installedName(for bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}
