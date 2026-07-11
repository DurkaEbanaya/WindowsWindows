import Foundation
import Cocoa

private struct ProxyLaunchRequest: Sendable {
    let generation: UUID
    let bundleURL: URL
    var isRevoked: Bool
}

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
    public struct ExistingProxy: Sendable {
        public let key: WindowKey
        public let processIdentity: ProcessIdentity?
    }

    public static let proxyBundlePrefix = Policy.proxyBundlePrefix
    public static let proxyExecutableName = "WindowsWindowsProxy"
    public static let previewFileName = "preview.png"
    private static let previewUpdatedNotificationName = "com.windowswindows.proxy.preview-updated"

    private let proxyAppsURL: URL
    private let proxyBinaryURL: URL
    private let mainSessionToken: String
    private let fileManager = FileManager.default

    /// Running proxy handles, чтобы управлять их жизненным циклом.
    /// Key = WindowKey.stringValue (для IPC-имён).
    private var runningProxies: [String: NSRunningApplication] = [:]
    private var desiredProxyKeys: Set<String> = []
    private var upgradingProxyKeys: Set<String> = []
    private var launchRequests: [String: ProxyLaunchRequest] = [:]
    private var lateLaunchCleanups: [UUID: LateLaunchCleanup] = [:]
    private var isShuttingDown = false
    private let lock = NSLock()
    private let bundleMutationLock = NSRecursiveLock()

    public init(proxyAppsURL: URL, proxyBinaryURL: URL, mainSessionToken: String = UUID().uuidString) {
        self.proxyAppsURL = proxyAppsURL
        self.proxyBinaryURL = proxyBinaryURL
        self.mainSessionToken = mainSessionToken
    }

    /// Создать/обновить бандл и запустить прокси если не running.
    ///
    /// - Parameter window: целевое окно.
    /// - Parameter snapshot: превью для иконки (опционально).
    /// - Returns: URL созданного/обновлённого бандла.
    @discardableResult
    public func ensure(window: ObservedWindow, snapshot: NSImage?) throws -> URL {
        bundleMutationLock.lock()
        defer { bundleMutationLock.unlock() }
        lock.lock()
        guard !isShuttingDown else {
            lock.unlock()
            throw NSError(domain: "ProxyFactory", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Proxy factory is shutting down"
            ])
        }
        desiredProxyKeys.insert(window.key.stringValue)
        lock.unlock()

        let bundleURL = bundleURL(for: window)
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

        migrateRunningProxyIfNeeded(key: window.key.stringValue, canonicalURL: bundleURL)

        // 5. Запустить прокси-процесс, если не running.
        try launchIfNeeded(key: window.key.stringValue, bundleURL: bundleURL)

        // Once the canonical bundle is live, remove any legacy/path-renamed
        // bundles for the same identity. Identity comes from plist metadata,
        // never from a mutable human-readable filename.
        try removeDuplicateBundles(for: window.key, keeping: bundleURL)

        return bundleURL
    }

    /// Удалить прокси для конкретного окна: terminate процесса + удалить бандл.
    public func remove(windowKey: WindowKey) throws {
        bundleMutationLock.lock()
        defer { bundleMutationLock.unlock() }
        let keyStr = windowKey.stringValue
        guard terminateProxy(key: keyStr) else { return }
        for bundleURL in bundleURLs(for: windowKey) {
            try removeBundle(at: bundleURL)
        }
    }

    /// Удалить все прокси, чьи ключи не в `validKeys`.
    @discardableResult
    public func cleanup(validKeys: Set<WindowKey>) throws -> [WindowKey] {
        bundleMutationLock.lock()
        defer { bundleMutationLock.unlock() }
        guard let entries = try? fileManager.contentsOfDirectory(at: proxyAppsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var removed: [WindowKey] = []
        for entry in entries where entry.pathExtension == "app" {
            guard let key = windowKey(forBundleAt: entry) else {
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
        existingProxies().map(\.key)
    }

    public func existingProxies() -> [ExistingProxy] {
        bundleMutationLock.lock()
        defer { bundleMutationLock.unlock() }
        guard let entries = try? fileManager.contentsOfDirectory(at: proxyAppsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { entry in
            guard entry.pathExtension == "app" else { return nil }
            return existingProxy(forBundleAt: entry)
        }
    }

    @discardableResult
    public func removeInvalidProxyBundles() throws -> [URL] {
        bundleMutationLock.lock()
        defer { bundleMutationLock.unlock() }
        let entries = try fileManager.contentsOfDirectory(
            at: proxyAppsURL,
            includingPropertiesForKeys: nil
        )
        var removedURLs: [URL] = []
        for entry in entries
        where entry.pathExtension == "app" && existingProxy(forBundleAt: entry) == nil {
            let canonicalURL = entry.standardizedFileURL
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleURL?.standardizedFileURL == canonicalURL }
                .forEach { forceProxyTermination($0) }
            try removeBundle(at: entry)
            removedURLs.append(entry)
        }
        return removedURLs
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
        for key in launchRequests.keys {
            launchRequests[key]?.isRevoked = true
        }
        lock.unlock()

        for (_, app) in proxies {
            forceProxyTermination(app)
        }
        for key in existingProxyKeys() {
            let bundleIdentifier = Self.proxyBundlePrefix + key.stringValue
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .forEach { forceProxyTermination($0) }
        }
        _ = try? removeInvalidProxyBundles()
    }

    // MARK: - Internal

    private func buildInfoPlist(window: ObservedWindow) throws -> Data {
        let bid = Self.proxyBundlePrefix + window.key.stringValue
        let presentation = ProxyPresentation(appName: window.appName, windowTitle: window.title)
        let displayName = presentation.displayName

        guard let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let mainIdentity = ProcessIdentity.live(processIdentifier: ProcessInfo.processInfo.processIdentifier) else {
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
            "WWProcessStartSeconds": window.processIdentity.startTimeSeconds,
            "WWProcessStartMicroseconds": window.processIdentity.startTimeMicroseconds,
            "WWWindowNumber": Int(window.windowNumber),
            "WWAppName": window.appName,
            "WWTitle": window.title,
            "WWMainPID": Int(ProcessInfo.processInfo.processIdentifier),
            "WWMainProcessStartSeconds": mainIdentity.startTimeSeconds,
            "WWMainProcessStartMicroseconds": mainIdentity.startTimeMicroseconds,
            "WWMainSessionToken": mainSessionToken,
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

    private func bundleURL(for window: ObservedWindow) -> URL {
        let presentation = ProxyPresentation(appName: window.appName, windowTitle: window.title)
        let name = "\(presentation.bundlePathComponent)-\(window.key.stringValue).app"
        return proxyAppsURL.appendingPathComponent(name, isDirectory: true)
    }

    private func bundleURLs(for key: WindowKey) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: proxyAppsURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return entries.filter { $0.pathExtension == "app" && windowKey(forBundleAt: $0) == key }
    }

    private func windowKey(forBundleAt bundleURL: URL) -> WindowKey? {
        existingProxy(forBundleAt: bundleURL)?.key
    }

    private func existingProxy(forBundleAt bundleURL: URL) -> ExistingProxy? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let value = dictionary["WWWindowKey"] as? String else {
            return nil
        }
        guard let key = WindowKey(stringValue: value) else { return nil }
        let identity: ProcessIdentity?
        if let seconds = dictionary["WWProcessStartSeconds"] as? NSNumber,
           let microseconds = dictionary["WWProcessStartMicroseconds"] as? NSNumber {
            identity = ProcessIdentity(
                processIdentifier: key.appPID,
                startTimeSeconds: seconds.uint64Value,
                startTimeMicroseconds: microseconds.uint64Value
            )
        } else {
            identity = nil
        }
        return ExistingProxy(key: key, processIdentity: identity)
    }

    private func removeDuplicateBundles(for key: WindowKey, keeping canonicalURL: URL) throws {
        let bundleIdentifier = Self.proxyBundlePrefix + key.stringValue
        let runningURLs = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .compactMap { $0.bundleURL?.standardizedFileURL }
        )
        for bundleURL in bundleURLs(for: key)
        where bundleURL.standardizedFileURL != canonicalURL.standardizedFileURL
            && !runningURLs.contains(bundleURL.standardizedFileURL) {
            try removeBundle(at: bundleURL)
        }
    }

    private func migrateRunningProxyIfNeeded(key: String, canonicalURL: URL) {
        let bundleIdentifier = Self.proxyBundlePrefix + key
        let canonical = canonicalURL.standardizedFileURL
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard instances.contains(where: { $0.bundleURL?.standardizedFileURL != canonical }) else {
            return
        }
        beginProxyUpgrade(key: key)
        DiagnosticJournal.shared.log("proxy", "path_migration_requested", fields: [
            "key": key,
            "canonicalURL": canonical.path,
            "runningURLs": instances.compactMap { $0.bundleURL?.path }
        ])
    }

    /// Запустить прокси-процесс если он не running или упал.
    private func launchIfNeeded(key: String, bundleURL: URL) throws {
        let bundleIdentifier = Self.proxyBundlePrefix + key
        lock.lock()
        let shuttingDown = isShuttingDown
        let existing = runningProxies[key]
        let isUpgrading = upgradingProxyKeys.contains(key)
        let isLaunching = launchRequests[key] != nil
        lock.unlock()

        guard !shuttingDown else { return }

        if isUpgrading {
            let oldInstances = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            )
            if !oldInstances.isEmpty {
                oldInstances.forEach { forceProxyTermination($0) }
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

        // Never submit a new LaunchServices request while any process with the
        // same bundle identity still exists. LaunchServices may otherwise
        // return that old process for the new request, making generations
        // fundamentally indistinguishable.
        let untrackedInstances = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        if !untrackedInstances.isEmpty {
            lock.lock()
            upgradingProxyKeys.insert(key)
            runningProxies.removeValue(forKey: key)
            lock.unlock()
            untrackedInstances.forEach {
                forceProxyTermination($0)
            }
            return
        }

        // Запускаем через NSWorkspace.open — это создаёт running app,
        // и Dock показывает tile.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false  // не красть фокус при запуске
        config.hides = false
        config.createsNewApplicationInstance = false

        lock.lock()
        guard !isShuttingDown, launchRequests[key] == nil else {
            lock.unlock()
            return
        }
        let generation = UUID()
        launchRequests[key] = ProxyLaunchRequest(
            generation: generation,
            bundleURL: bundleURL.standardizedFileURL,
            isRevoked: false
        )
        lock.unlock()

        DiagnosticJournal.shared.log("proxy", "launch_requested", fields: [
            "key": key,
            "bundleURL": bundleURL.path
        ])

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { [weak self] app, error in
                guard let self else { return }

                self.lock.lock()
                let currentRequest = self.launchRequests[key]
                let ownsRequest = currentRequest?.generation == generation
                let matchesCanonicalURL = app?.bundleURL?.standardizedFileURL
                    == currentRequest?.bundleURL
                let desired = !self.isShuttingDown && self.desiredProxyKeys.contains(key)
                let accepted = ownsRequest
                    && currentRequest?.isRevoked == false
                    && matchesCanonicalURL
                    && desired
                    && app?.isTerminated == false
                if let app, accepted {
                    self.runningProxies[key] = app
                }
                let rejectedOwnedApplication = ownsRequest && app != nil && !accepted
                if rejectedOwnedApplication, let app {
                    self.forceProxyTermination(app)
                }
                if rejectedOwnedApplication && desired {
                    self.upgradingProxyKeys.insert(key)
                    self.runningProxies.removeValue(forKey: key)
                }
                if ownsRequest {
                    self.launchRequests.removeValue(forKey: key)
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

                if accepted {
                    DiagnosticJournal.shared.log("proxy", "launched", fields: [
                        "key": key,
                        "pid": app.processIdentifier
                    ])
                } else if rejectedOwnedApplication {
                    self.terminateLateLaunch(app, key: key)
                    DiagnosticJournal.shared.log("proxy", "late_launch_terminated", fields: [
                        "key": key,
                        "pid": app.processIdentifier
                    ])
                } else if !ownsRequest {
                    DiagnosticJournal.shared.log("proxy", "stale_launch_ignored", fields: [
                        "key": key,
                        "pid": app.processIdentifier,
                        "generation": generation.uuidString
                    ])
                }
        }
    }

    private func terminateLateLaunch(_ app: NSRunningApplication, key: String) {
        if app.isTerminated {
            removeLateLaunchBundlesIfUndesired(key: key)
            return
        }
        let observer = LateLaunchCleanup { [weak self] cleanupID in
            guard let self else { return }
            self.lock.lock()
            guard self.lateLaunchCleanups[cleanupID] != nil else {
                self.lock.unlock()
                return
            }
            self.lateLaunchCleanups.removeValue(forKey: cleanupID)
            self.lock.unlock()
            self.removeLateLaunchBundlesIfUndesired(key: key)
        }
        lock.lock()
        lateLaunchCleanups[observer.id] = observer
        let requested = forceProxyTermination(app)
        if !requested {
            lateLaunchCleanups.removeValue(forKey: observer.id)
        }
        lock.unlock()
        guard requested else {
            observer.cancel()
            return
        }
        observer.start(application: app)
        if app.isTerminated {
            observer.finish()
        }
    }

    private func removeLateLaunchBundlesIfUndesired(key: String) {
        bundleMutationLock.lock()
        defer { bundleMutationLock.unlock() }
        lock.lock()
        let shouldRemove = !desiredProxyKeys.contains(key)
        lock.unlock()
        guard shouldRemove, let windowKey = WindowKey(stringValue: key) else { return }
        for url in bundleURLs(for: windowKey) {
            try? removeBundle(at: url)
        }
    }

    /// Завершить running прокси по ключу.
    private func terminateProxy(key: String) -> Bool {
        let bundleIdentifier = Self.proxyBundlePrefix + key
        lock.lock()
        desiredProxyKeys.remove(key)
        upgradingProxyKeys.remove(key)
        let isLaunching = launchRequests[key] != nil
        if isLaunching {
            launchRequests[key]?.isRevoked = true
        }
        let app = runningProxies.removeValue(forKey: key)
        lock.unlock()

        guard !isLaunching else { return false }

        var applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if let app, !applications.contains(where: { $0.processIdentifier == app.processIdentifier }) {
            applications.append(app)
        }
        applications.forEach {
            forceProxyTermination($0)
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
        launchRequests[key]?.isRevoked = true
        let tracked = runningProxies[key]
        lock.unlock()

        if let tracked { forceProxyTermination(tracked) }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .forEach { forceProxyTermination($0) }
        DiagnosticJournal.shared.log("proxy", "upgrade_requested", fields: [
            "key": key,
            "bundleID": bundleIdentifier
        ])
    }

    @discardableResult
    private func forceProxyTermination(_ app: NSRunningApplication) -> Bool {
        app.isTerminated || app.forceTerminate()
    }
}

private final class LateLaunchCleanup: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var cleanup: (@Sendable (UUID) -> Void)?

    init(cleanup: @escaping @Sendable (UUID) -> Void) {
        self.cleanup = cleanup
    }

    func start(application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  terminated.processIdentifier == processIdentifier else { return }
            self?.finish()
        }
        lock.lock()
        guard cleanup != nil else {
            lock.unlock()
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            return
        }
        self.observer = observer
        lock.unlock()
        if application.isTerminated {
            finish()
        }
    }

    func finish() {
        lock.lock()
        let observer = self.observer
        let cleanup = self.cleanup
        self.observer = nil
        self.cleanup = nil
        lock.unlock()
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        cleanup?(id)
    }

    func cancel() {
        lock.lock()
        let observer = self.observer
        self.observer = nil
        cleanup = nil
        lock.unlock()
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
