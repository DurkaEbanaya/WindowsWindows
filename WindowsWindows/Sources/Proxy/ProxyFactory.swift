import Foundation
import Cocoa

/// Создание, запуск и управление proxy-бандлами в Dock.
///
/// Каждый прокси — полноценный `.app` bundle:
/// ```
/// <windowKey>.app/
///   Contents/
///     Info.plist          <- CFBundleIdentifier=com.windowswindows.proxy.<key>
///     MacOS/WindowsWindowsProxy   <- исполняемый файл
///     Resources/icon.icns <- превью окна (снапшот)
/// ```
///
/// Контракт: tile появляется в Dock **только когда прокси-процесс running**.
/// Поэтому прокси запускается и живёт, пока живо окно. При исчезновении
/// окна main app терминирует прокси → tile исчезает.
///
/// Жизненный цикл:
/// - `ensure(window:)` — создать/обновить бандл + запустить прокси если не running.
/// - `remove(windowKey:)` — terminate прокси-процесс + удалить бандл.
/// - `cleanup(validKeys:)` — удалить все прокси, чьи ключи не в списке.
public final class ProxyFactory {

    public static let proxyBundlePrefix = Policy.proxyBundlePrefix
    public static let proxyExecutableName = "WindowsWindowsProxy"
    public static let iconFileName = "icon.icns"

    private let proxyAppsURL: URL
    private let proxyBinaryURL: URL
    private let fileManager = FileManager.default

    /// Running proxy handles, чтобы управлять их жизненным циклом.
    /// Key = WindowKey.stringValue (для IPC-имён).
    private var runningProxies: [String: NSRunningApplication] = [:]
    private var desiredProxyKeys: Set<String> = []
    private let lock = NSLock()

    public init(proxyAppsURL: URL, proxyBinaryURL: URL) {
        self.proxyAppsURL = proxyAppsURL
        self.proxyBinaryURL = proxyBinaryURL
    }

    /// Создать/обновить бандл и запустить прокси если не running.
    ///
    /// - Parameter window: целевое окно.
    /// - Parameter snapshot: превью для иконки (опционально).
    /// - Returns: URL созданного/обновлённого бандла.
    @discardableResult
    public func ensure(window: ObservedWindow, snapshot: NSImage?) throws -> URL {
        lock.lock()
        desiredProxyKeys.insert(window.key.stringValue)
        lock.unlock()

        let bundleURL = proxyAppsURL.appendingPathComponent("\(window.key.stringValue).app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macosURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        let bundleExists = fileManager.fileExists(atPath: bundleURL.path)

        if !bundleExists {
            try fileManager.createDirectory(at: macosURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        }

        // 1. Скопировать/обновить исполняемый файл.
        let execURL = macosURL.appendingPathComponent(Self.proxyExecutableName)
        try copyBinary(from: proxyBinaryURL, to: execURL)

        // 2. Записать Info.plist.
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let plistData = try buildInfoPlist(window: window)
        try plistData.write(to: infoPlistURL, options: [.atomic])

        // 3. Иконка-снапшот (если есть).
        if let snapshot = snapshot {
            let iconURL = resourcesURL.appendingPathComponent(Self.iconFileName)
            try writeIcon(from: snapshot, to: iconURL)
        }

        // 4. Регистрация в LaunchServices.
        try registerBundle(at: bundleURL)

        // 5. Запустить прокси-процесс, если не running.
        try launchIfNeeded(key: window.key.stringValue, bundleURL: bundleURL)

        return bundleURL
    }

    /// Удалить прокси для конкретного окна: terminate процесса + удалить бандл.
    public func remove(windowKey: WindowKey) throws {
        let keyStr = windowKey.stringValue
        terminateProxy(key: keyStr)
        let bundleURL = proxyAppsURL.appendingPathComponent("\(keyStr).app", isDirectory: true)
        try removeBundle(at: bundleURL)
    }

    /// Удалить все прокси, чьи ключи не в `validKeys`.
    @discardableResult
    public func cleanup(validKeys: Set<WindowKey>) throws -> [WindowKey] {
        guard let entries = try? fileManager.contentsOfDirectory(at: proxyAppsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var removed: [WindowKey] = []
        for entry in entries where entry.pathExtension == "app" {
            let name = entry.deletingPathExtension().lastPathComponent
            guard let key = WindowKey(stringValue: name) else {
                try? removeBundle(at: entry)
                continue
            }
            if !validKeys.contains(key) {
                terminateProxy(key: key.stringValue)
                try? removeBundle(at: entry)
                removed.append(key)
            }
        }
        return removed
    }

    /// Перечислить все существующие прокси-бандлы на диске.
    public func existingProxyKeys() -> [WindowKey] {
        guard let entries = try? fileManager.contentsOfDirectory(at: proxyAppsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { entry in
            guard entry.pathExtension == "app" else { return nil }
            let name = entry.deletingPathExtension().lastPathComponent
            return WindowKey(stringValue: name)
        }
    }

    /// Завершить все running прокси (при завершении main app).
    public func terminateAll() {
        lock.lock()
        let proxies = runningProxies
        runningProxies.removeAll()
        desiredProxyKeys.removeAll()
        lock.unlock()
        for (_, app) in proxies {
            app.terminate()
        }
    }

    // MARK: - Internal

    private func buildInfoPlist(window: ObservedWindow) throws -> Data {
        let bid = Self.proxyBundlePrefix + window.key.stringValue
        let displayName = window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"

        guard let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            throw NSError(domain: "ProxyFactory", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Main bundle version metadata is missing or invalid"
            ])
        }

        let plist: [String: Any] = [
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleIdentifier": bid,
            "CFBundleExecutable": Self.proxyExecutableName,
            "CFBundleVersion": bundleVersion,
            "CFBundleShortVersionString": shortVersion,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": Self.iconFileName,
            "LSMinimumSystemVersion": "14.0",
            // Foreground app (без LSUIElement) — Dock показывает tile для running.
            // setActivationPolicy(.accessory) в runtime убирает menu bar / cmd-tab,
            // но tile в Dock остаётся, т.к. LSRegisterURL зарегистрировал как Foreground.
            "LSUIElement": false,
            "NSHighResolutionCapable": true,
            "WWWindowKey": window.key.stringValue,
            "WWAppPID": Int(window.appPID),
            "WWWindowNumber": Int(window.windowNumber),
            "WWAppName": window.appName,
            "WWTitle": window.title,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func copyBinary(from source: URL, to dest: URL) throws {
        if fileManager.fileExists(atPath: dest.path) {
            if let s = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               let d = try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               s == d {
                return
            }
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: source, to: dest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    private func writeIcon(from image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return
        }
        // PNG записывается как icon.icns — Dock корректно отображает PNG
        // с указанным CFBundleIconFile.
        try pngData.write(to: url, options: [.atomic])
    }

    private func registerBundle(at url: URL) throws {
        let status = LSRegisterURL(url as CFURL, true)
        if status != noErr {
            throw NSError(domain: "ProxyFactory", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "LSRegisterURL failed for \(url.path) (status \(status))"
            ])
        }
    }

    private func removeBundle(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Запустить прокси-процесс если он не running или упал.
    private func launchIfNeeded(key: String, bundleURL: URL) throws {
        lock.lock()
        let existing = runningProxies[key]
        lock.unlock()

        // Если уже running и не завершён — ничего не делаем.
        if let app = existing, !app.isTerminated {
            DiagnosticJournal.shared.log("proxy", "reuse_running", fields: [
                "key": key,
                "pid": app.processIdentifier
            ])
            return
        }

        // Запускаем через NSWorkspace.open — это создаёт running app,
        // и Dock показывает tile.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false  // не красть фокус при запуске
        config.hides = false
        config.createsNewApplicationInstance = false

        DiagnosticJournal.shared.log("proxy", "launch_requested", fields: [
            "key": key,
            "bundleURL": bundleURL.path
        ])

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { [weak self] app, error in
            guard let self else { return }
            guard let app else {
                DiagnosticJournal.shared.log("proxy", "launch_failed", fields: [
                    "key": key,
                    "error": error?.localizedDescription ?? "unknown"
                ])
                return
            }

            self.lock.lock()
            let stillDesired = self.desiredProxyKeys.contains(key)
            if stillDesired {
                self.runningProxies[key] = app
            }
            self.lock.unlock()

            if stillDesired {
                DiagnosticJournal.shared.log("proxy", "launched", fields: [
                    "key": key,
                    "pid": app.processIdentifier
                ])
            } else {
                app.terminate()
                DiagnosticJournal.shared.log("proxy", "late_launch_terminated", fields: [
                    "key": key,
                    "pid": app.processIdentifier
                ])
            }
        }
    }

    /// Завершить running прокси по ключу.
    private func terminateProxy(key: String) {
        lock.lock()
        desiredProxyKeys.remove(key)
        let app = runningProxies.removeValue(forKey: key)
        lock.unlock()
        let terminated = app?.terminate() ?? true
        DiagnosticJournal.shared.log("proxy", "terminated", fields: [
            "key": key,
            "pid": app?.processIdentifier ?? -1,
            "requested": terminated
        ])
    }
}
