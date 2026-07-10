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
///     Resources/preview.png <- превью окна (снапшот)
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
/// Bundle mutation is confined to `RefreshLoop`; completion-handler access to
/// process ownership is protected by `lock`.
public final class ProxyFactory: @unchecked Sendable {

    public static let proxyBundlePrefix = Policy.proxyBundlePrefix
    public static let proxyExecutableName = "WindowsWindowsProxy"
    public static let previewFileName = "preview.png"
    private static let previewUpdatedNotificationName = "com.windowswindows.proxy.preview-updated"

    private let proxyAppsURL: URL
    private let proxyBinaryURL: URL
    private let fileManager = FileManager.default

    /// Running proxy handles, чтобы управлять их жизненным циклом.
    /// Key = WindowKey.stringValue (для IPC-имён).
    private var runningProxies: [String: NSRunningApplication] = [:]
    private var desiredProxyKeys: Set<String> = []
    private var upgradingProxyKeys: Set<String> = []
    private var launchingProxyKeys: Set<String> = []
    private var isShuttingDown = false
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
        guard !isShuttingDown else {
            lock.unlock()
            throw NSError(domain: "ProxyFactory", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Proxy factory is shutting down"
            ])
        }
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
        let binaryChanged = try copyBinary(from: proxyBinaryURL, to: execURL)
        if binaryChanged {
            beginProxyUpgrade(key: window.key.stringValue)
        }

        // 2. Записать Info.plist.
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let plistData = try buildInfoPlist(window: window)
        try plistData.write(to: infoPlistURL, options: [.atomic])

        // 3. Иконка-снапшот (если есть).
        if let snapshot = snapshot {
            let iconURL = resourcesURL.appendingPathComponent(Self.previewFileName)
            try writeIcon(from: snapshot, to: iconURL)
            notifyPreviewUpdated(key: window.key.stringValue)
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
        guard terminateProxy(key: keyStr) else { return }
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
                if terminateProxy(key: key.stringValue) {
                    try? removeBundle(at: entry)
                    removed.append(key)
                }
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

    /// Permanently stop this factory and terminate every generated proxy.
    /// Once shutdown starts, neither an active refresh nor an asynchronous
    /// LaunchServices completion can make a proxy desired again.
    public func shutdown() {
        lock.lock()
        isShuttingDown = true
        let proxies = runningProxies
        runningProxies.removeAll()
        desiredProxyKeys.removeAll()
        upgradingProxyKeys.removeAll()
        launchingProxyKeys.removeAll()
        lock.unlock()

        for (_, app) in proxies {
            app.terminate()
        }
        for key in existingProxyKeys() {
            let bundleIdentifier = Self.proxyBundlePrefix + key.stringValue
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .forEach { $0.terminate() }
        }
    }

    // MARK: - Internal

    private func buildInfoPlist(window: ObservedWindow) throws -> Data {
        let bid = Self.proxyBundlePrefix + window.key.stringValue
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = title.isEmpty ? window.appName : title

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
            "CFBundleIconFile": Self.previewFileName,
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
            "WWMainPID": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    @discardableResult
    private func copyBinary(from source: URL, to dest: URL) throws -> Bool {
        if fileManager.fileExists(atPath: dest.path) {
            if fileManager.contentsEqual(atPath: source.path, andPath: dest.path) {
                return false
            }
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: source, to: dest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return true
    }

    private func writeIcon(from image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ProxyFactory", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Snapshot cannot be encoded as PNG"
            ])
        }
        try pngData.write(to: url, options: [.atomic])
    }

    private func notifyPreviewUpdated(key: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.previewUpdatedNotificationName),
            object: key,
            userInfo: nil,
            deliverImmediately: true
        )
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
        let bundleIdentifier = Self.proxyBundlePrefix + key
        lock.lock()
        let shuttingDown = isShuttingDown
        let existing = runningProxies[key]
        let isUpgrading = upgradingProxyKeys.contains(key)
        let isLaunching = launchingProxyKeys.contains(key)
        lock.unlock()

        guard !shuttingDown else { return }

        if isUpgrading {
            let oldInstances = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            )
            if !oldInstances.isEmpty {
                oldInstances.forEach { $0.terminate() }
                return
            }
            lock.lock()
            upgradingProxyKeys.remove(key)
            runningProxies.removeValue(forKey: key)
            lock.unlock()
        }

        // Если уже running и не завершён — ничего не делаем.
        if let app = existing, !app.isTerminated {
            DiagnosticJournal.shared.log("proxy", "reuse_running", fields: [
                "key": key,
                "pid": app.processIdentifier
            ])
            return
        }

        guard !isLaunching else { return }

        // Запускаем через NSWorkspace.open — это создаёт running app,
        // и Dock показывает tile.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false  // не красть фокус при запуске
        config.hides = false
        config.createsNewApplicationInstance = false

        lock.lock()
        guard !isShuttingDown, !launchingProxyKeys.contains(key) else {
            lock.unlock()
            return
        }
        launchingProxyKeys.insert(key)
        lock.unlock()

        DiagnosticJournal.shared.log("proxy", "launch_requested", fields: [
            "key": key,
            "bundleURL": bundleURL.path
        ])

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { [weak self] app, error in
                guard let self else { return }

                self.lock.lock()
                self.launchingProxyKeys.remove(key)
                let stillDesired = !self.isShuttingDown && self.desiredProxyKeys.contains(key)
                if let app, stillDesired {
                    self.runningProxies[key] = app
                }
                self.lock.unlock()

                guard let app else {
                    let launchError = error ?? NSError(domain: "ProxyFactory", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "LaunchServices returned no proxy application"
                    ])
                    DiagnosticJournal.shared.log("proxy", "launch_failed", fields: [
                        "key": key,
                        "error": launchError.localizedDescription
                    ])
                    return
                }

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
    private func terminateProxy(key: String) -> Bool {
        let bundleIdentifier = Self.proxyBundlePrefix + key
        lock.lock()
        desiredProxyKeys.remove(key)
        upgradingProxyKeys.remove(key)
        let isLaunching = launchingProxyKeys.contains(key)
        let app = runningProxies.removeValue(forKey: key)
        lock.unlock()

        guard !isLaunching else { return false }

        var applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if let app, !applications.contains(where: { $0.processIdentifier == app.processIdentifier }) {
            applications.append(app)
        }
        applications.forEach {
            if !$0.terminate() {
                _ = $0.forceTerminate()
            }
        }
        let terminated = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        DiagnosticJournal.shared.log("proxy", "terminated", fields: [
            "key": key,
            "pids": applications.map(\.processIdentifier),
            "requested": terminated
        ])
        return terminated
    }

    private func beginProxyUpgrade(key: String) {
        let bundleIdentifier = Self.proxyBundlePrefix + key
        lock.lock()
        upgradingProxyKeys.insert(key)
        let tracked = runningProxies[key]
        lock.unlock()

        tracked?.terminate()
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .forEach { $0.terminate() }
        DiagnosticJournal.shared.log("proxy", "upgrade_requested", fields: [
            "key": key,
            "bundleID": bundleIdentifier
        ])
    }
}
