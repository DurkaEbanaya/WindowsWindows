import Cocoa
@preconcurrency import ApplicationServices
import Darwin

public final class MainInstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    public static func acquire(lockURL: URL) throws -> MainInstanceLock? {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        return MainInstanceLock(descriptor: descriptor)
    }

    public static func defaultLockURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent(ConfigStore.appName, isDirectory: true)
            .appendingPathComponent("main.lock", isDirectory: false)
    }
}

/// Координатор: связывает все модули воедино и управляет жизненным циклом.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var configStore: ConfigStore!
    private var discovery: WindowDiscovery!
    private var snapshotter: WindowSnapshotter!
    private var factory: ProxyFactory!
    private var ipc: ProxyIPC!
    private var windowController: WindowController!
    private var focusTracker: WindowFocusTracker!
    private var refreshLoop: RefreshLoop!
    private var settingsWindowController: SettingsWindowController!
    private let hotKeyController = GlobalHotKeyController()
    private let optionTabSwitcher = OptionTabSwitcherController()
    private let dockRepeatClickController = DockRepeatClickController()
    private var optionTabSwitcherEnabled = false
    private let updateCheckService = UpdateCheckService()
    private var mainInstanceLock: MainInstanceLock?
    private let mainSessionToken = UUID().uuidString
    private var commandObserver: NSObjectProtocol?

    // Кэш текущих окон для обработки IPC-активаций.
    // Обновляется RefreshLoop.tick(). IPC-handler ищет здесь по windowKey.
    private var knownWindows: [WindowKey: ObservedWindow] = [:]
    private var knownPreviews: [WindowKey: NSImage] = [:]
    private var dockWindowPreferences = DockWindowPreferenceState()
    private let knownWindowsLock = NSLock()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let lock = try MainInstanceLock.acquire(lockURL: MainInstanceLock.defaultLockURL()) else {
                NSLog("Another WindowsWindows instance is already running; exiting before mutating proxy state.")
                MainAppCommandIPC.requestOpenSettings()
                NSApp.terminate(nil)
                return
            }
            mainInstanceLock = lock
        } catch {
            NSLog("Main instance lock failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        // 1. Проверка Accessibility permission. Без него discovery AX-часть
        //    молча вернёт пусто, окно не будут иметь axWindow handle.
        //    Prompt показывается системой при первом AX-вызове, но мы
        //    явно триггерим диалог, чтобы пользователь сразу понял.
        requestAccessibilityPermission()

        // 2. Инициализация модулей.
        do {
            configStore = try ConfigStore()
            DiagnosticJournal.shared.configure(supportURL: configStore.supportURL)
        } catch {
            NSLog("ConfigStore init failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        discovery = WindowDiscovery()
        snapshotter = WindowSnapshotter()

        // Proxy binary: лежит в Resources main app bundle.
        guard let proxyBinaryURL = Bundle.main.url(forResource: "WindowsWindowsProxy", withExtension: nil) else {
            NSLog("FATAL: WindowsWindowsProxy binary not found in main bundle. Build is misconfigured.")
            NSApp.terminate(nil)
            return
        }
        factory = ProxyFactory(
            proxyAppsURL: configStore.proxyAppsURL,
            proxyBinaryURL: proxyBinaryURL,
            mainSessionToken: mainSessionToken
        )

        ipc = ProxyIPC(sessionToken: mainSessionToken)
        windowController = WindowController()
        settingsWindowController = SettingsWindowController(store: configStore) { [weak self] workspace in
            self?.workspaceDidChange(workspace)
        }
        focusTracker = WindowFocusTracker()
        focusTracker.start(
            onFocusedWindowChanged: { [weak self] key in
                self?.optionTabSwitcher.noteFocusedWindow(key)
                _ = self?.dockWindowPreferences.observeFocusedWindow(key, now: Date())
            },
            onWindowMinimized: { [weak self] key in
                self?.dockWindowPreferences.noteMinimized(key)
            },
            onWindowRestored: { [weak self] key in
                self?.dockWindowPreferences.noteRestored(key)
            }
        )
        refreshLoop = RefreshLoop(
            discovery: discovery,
            factory: factory,
            snapshotter: snapshotter,
            configStore: configStore
        )

        // 3. Подписка на IPC-активации прокси.
        ipc.startListening { [weak self] message in
            self?.handleProxyMessage(message)
        }
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: MainAppCommandIPC.openSettingsNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }

        // 3b. Обновление knownWindows из RefreshLoop.
        let loop = refreshLoop!
        Task {
            await loop.setOnWindowsUpdated { [weak self] map, previews in
                self?.knownWindowsLock.lock()
                self?.knownWindows = map
                self?.knownPreviews = previews
                self?.knownWindowsLock.unlock()
            }
            await loop.start()
        }

        NSLog("WindowsWindows started. ProxyApps dir: \(configStore.proxyAppsURL.path)")
        DiagnosticJournal.shared.log("lifecycle", "started", fields: [
            "proxyAppsURL": configStore.proxyAppsURL.path,
            "axResolverAvailable": AXWindowIDResolver.shared.isAvailable,
            "accessibilityTrusted": AXIsProcessTrusted()
        ])

        requestScreenCapturePermissionIfNeeded()
        applyWorkspaceServicesFromDisk()
        dockRepeatClickController.start(
            canToggle: { [weak self] application in
                self?.dockTargetWindow(for: application) != nil
            },
            toggle: { [weak self] application in
                guard let self, let window = self.dockTargetWindow(for: application) else { return }
                let wasFocused = self.focusTracker.currentFocusedWindowKey() == window.key
                self.dockWindowPreferences.pin(window.key)
                self.windowController.toggle(window: window, wasFocusedBeforeProxy: wasFocused)
                DiagnosticJournal.shared.log("dock_click", "exact_window_toggle", fields: [
                    "key": window.key.stringValue,
                    "wasFocused": wasFocused
                ])
            },
            closeProxy: { [weak self] key in
                self?.handleProxyCloseRequest(key: key)
            },
            userInteraction: { [weak self] pid in
                self?.dockWindowPreferences.noteUserInteraction(with: pid, now: Date())
            }
        )
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        factory?.shutdown()
        ipc?.stopListening()
        if let commandObserver {
            DistributedNotificationCenter.default().removeObserver(commandObserver)
        }
        hotKeyController.stop()
        optionTabSwitcher.stop()
        dockRepeatClickController.stop()
        focusTracker?.stop()
        if let refreshLoop {
            Task { await refreshLoop.shutdown() }
        }
        return .terminateNow
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: - Internal

    private func requestAccessibilityPermission() {
        // Повторный запрос: prompt=true всегда показывает диалог, даже если
        // пользователь ранее отказал — это нужное поведение для диагностики.
        let opts: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            NSLog("Accessibility permission not granted. AX-based window control will be limited.")
            // После первого отказа TCC может не показать prompt повторно.
            // Открываем точную панель Privacy & Security → Accessibility.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        // Screen Capture permission запросится автоматически при первом
        // SCShareableContent / captureImage вызове (TCC диалог). Не требуем
        // здесь отдельной логики — permissions запрашиваются по требованию.
    }

    private func requestScreenCapturePermissionIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }

        let granted = CGRequestScreenCaptureAccess()
        DiagnosticJournal.shared.log("permission", "screen_capture_requested", fields: [
            "granted": granted
        ])
        if !granted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleProxyMessage(_ message: ProxyIPCMessage) {
        switch message.action {
        case .activate:
            handleProxyActivation(key: message.windowKey)
        case .close:
            handleProxyCloseRequest(key: message.windowKey)
        }
    }

    private func openSettings() {
        settingsWindowController.show()
    }

    private func workspaceDidChange(_ workspace: WorkspaceConfig) {
        applyWorkspaceServices(workspace)
        Task { await refreshLoop.tick() }
    }

    private func applyWorkspaceServicesFromDisk() {
        do {
            applyWorkspaceServices(try configStore.loadWorkspace())
        } catch {
            DiagnosticJournal.shared.log("workspace", "service_apply_load_failed", fields: [
                "error": error.localizedDescription
            ])
        }
    }

    private func applyWorkspaceServices(_ workspace: WorkspaceConfig) {
        windowController.minimizeOnRepeatClick = workspace.behavior.minimizeOnRepeatClick
        dockRepeatClickController.isPrimaryClickEnabled = workspace.behavior.minimizeOnRepeatClick
        applyOptionTabSwitcher(enabled: workspace.behavior.optionTabSwitcherEnabled)
        hotKeyController.apply(config: workspace.hotKeys) { [weak self] direction in
            self?.traverseActiveProfile(direction)
        }
        LoginItemService.apply(enabled: workspace.loginItem.isEnabled)
        Task { [updateCheckService] in
            await updateCheckService.check(config: workspace.updates)
        }
    }

    private func applyOptionTabSwitcher(enabled: Bool) {
        guard optionTabSwitcherEnabled != enabled else { return }
        optionTabSwitcherEnabled = enabled
        if enabled {
            optionTabSwitcher.start(
                windows: { [weak self] in self?.activeProfileWindows() ?? [] },
                focusedKey: { [weak self] in self?.focusTracker.currentFocusedWindowKey() },
                preview: { [weak self] key in self?.previewImage(for: key) },
                activate: { [weak self] window in
                    self?.dockWindowPreferences.pin(window.key)
                    self?.windowController.raise(window: window)
                }
            )
        } else {
            optionTabSwitcher.stop()
        }
    }

    private func traverseActiveProfile(_ direction: ProfileTraversalDirection) {
        do {
            let workspace = try configStore.loadWorkspace()
            let orderedKeys = workspace.activeProfile?.windowKeys.compactMap(WindowKey.init(stringValue:)) ?? []
            guard !orderedKeys.isEmpty else { return }
            knownWindowsLock.lock()
            let windows = knownWindows
            knownWindowsLock.unlock()
            let availableKeys = orderedKeys.filter { windows[$0] != nil }
            guard !availableKeys.isEmpty else { return }
            let focused = focusTracker.currentFocusedWindowKey()
            let targetKey = nextKey(in: availableKeys, from: focused, direction: direction)
            guard let window = windows[targetKey] else { return }
            dockWindowPreferences.pin(window.key)
            windowController.raise(window: window)
            DiagnosticJournal.shared.log("hotkey", "profile_traversal", fields: [
                "direction": String(describing: direction),
                "key": targetKey.stringValue
            ])
        } catch {
            DiagnosticJournal.shared.log("hotkey", "profile_traversal_failed", fields: [
                "error": error.localizedDescription
            ])
        }
    }

    private func activeProfileWindows() -> [ObservedWindow] {
        guard let orderedKeys = try? configStore.loadWorkspace().activeProfile?.windowKeys.compactMap(WindowKey.init(stringValue:)) else {
            return []
        }
        knownWindowsLock.lock()
        let windows = knownWindows
        knownWindowsLock.unlock()
        return orderedKeys.compactMap { windows[$0] }
    }

    private func previewImage(for key: WindowKey) -> NSImage? {
        knownWindowsLock.lock()
        let preview = knownPreviews[key]
        knownWindowsLock.unlock()
        return preview ?? factory.previewImage(for: key)
    }

    private func dockTargetWindow(for application: NSRunningApplication) -> ObservedWindow? {
        guard let key = dockWindowPreferences.targetKey(for: application.processIdentifier) else { return nil }
        knownWindowsLock.lock()
        let window = knownWindows[key]
        knownWindowsLock.unlock()
        if window == nil {
            dockWindowPreferences.invalidateTarget(for: application.processIdentifier)
        }
        return window
    }

    private func nextKey(
        in keys: [WindowKey],
        from focused: WindowKey?,
        direction: ProfileTraversalDirection
    ) -> WindowKey {
        guard let focused, let index = keys.firstIndex(of: focused) else {
            return direction == .next ? keys[0] : keys[keys.count - 1]
        }
        switch direction {
        case .next:
            return keys[(index + 1) % keys.count]
        case .previous:
            return keys[(index - 1 + keys.count) % keys.count]
        }
    }

    /// Обработка клика по прокси в Dock.
    /// Прокси прислал windowKey → находим окно в knownWindows → toggle.
    private func handleProxyActivation(key: WindowKey) {
        dockWindowPreferences.pin(key)
        let wasFocusedBeforeProxy = focusTracker.wasFocusedImmediatelyBeforeProxy(key)
        DiagnosticJournal.shared.log("ipc", "proxy_clicked", fields: [
            "key": key.stringValue,
            "wasFocusedBeforeProxy": wasFocusedBeforeProxy
        ])
        knownWindowsLock.lock()
        let window = knownWindows[key]
        knownWindowsLock.unlock()

        guard let window = window else {
            let loop = refreshLoop!
            Task { [weak self] in
                guard let self else { return }
                if let found = await loop.resolveWindow(key: key) {
                    DiagnosticJournal.shared.log("ipc", "window_refreshed_for_click", fields: [
                        "key": key.stringValue,
                        "title": found.title
                    ])
                    windowController.toggle(
                        window: found,
                        wasFocusedBeforeProxy: wasFocusedBeforeProxy
                    )
                } else {
                    DiagnosticJournal.shared.log("ipc", "window_not_found_for_click", fields: [
                        "key": key.stringValue
                    ])
                }
            }
            return
        }
        windowController.toggle(
            window: window,
            wasFocusedBeforeProxy: wasFocusedBeforeProxy
        )
    }

    /// Обработка Dock → Quit/Завершить на proxy tile.
    /// Это запрос закрыть конкретное реальное окно, а не завершить proxy app.
    private func handleProxyCloseRequest(key: WindowKey) {
        DiagnosticJournal.shared.log("ipc", "proxy_close_requested", fields: [
            "key": key.stringValue
        ])

        knownWindowsLock.lock()
        let cachedWindow = knownWindows[key]
        knownWindowsLock.unlock()

        if let cachedWindow {
            closeWindowAndSuppressProxy(cachedWindow)
            return
        }

        let loop = refreshLoop!
        Task { [weak self] in
            guard let self else { return }
            if let found = await loop.resolveWindow(key: key) {
                await MainActor.run {
                    self.closeWindowAndSuppressProxy(found)
                }
            } else {
                DiagnosticJournal.shared.log("ipc", "window_not_found_for_close", fields: [
                    "key": key.stringValue
                ])
            }
        }
    }

    private func closeWindowAndSuppressProxy(_ window: ObservedWindow) {
        Task { [weak self] in
            guard let self else { return }
            await self.refreshLoop.suppressProxyLaunch(forCloseOf: window.key)
            await MainActor.run {
                self.removeProxyAndCloseWindow(window)
            }
        }
    }

    private func removeProxyAndCloseWindow(_ window: ObservedWindow) {
        do {
            try factory.remove(windowKey: window.key)
        } catch {
            DiagnosticJournal.shared.log("proxy", "remove_for_close_failed", fields: [
                "key": window.key.stringValue,
                "error": error.localizedDescription
            ])
        }

        let result = windowController.close(window: window)
        DiagnosticJournal.shared.log("window_control", "close_requested", fields: [
            "key": window.key.stringValue,
            "result": result.rawValue
        ])
    }
}
