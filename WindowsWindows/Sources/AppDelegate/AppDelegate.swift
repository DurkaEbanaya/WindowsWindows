import Cocoa
import ApplicationServices

/// Координатор: связывает все модули воедино и управляет жизненным циклом.
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var configStore: ConfigStore!
    private var discovery: WindowDiscovery!
    private var snapshotter: WindowSnapshotter!
    private var factory: ProxyFactory!
    private var ipc: ProxyIPC!
    private var windowController: WindowController!
    private var focusTracker: WindowFocusTracker!
    private var refreshLoop: RefreshLoop!

    // Кэш текущих окон для обработки IPC-активаций.
    // Обновляется RefreshLoop.tick(). IPC-handler ищет здесь по windowKey.
    private var knownWindows: [WindowKey: ObservedWindow] = [:]
    private let knownWindowsLock = NSLock()

    public func applicationDidFinishLaunching(_ notification: Notification) {
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
            proxyBinaryURL: proxyBinaryURL
        )

        ipc = ProxyIPC()
        windowController = WindowController()
        focusTracker = WindowFocusTracker()
        focusTracker.start()
        refreshLoop = RefreshLoop(
            discovery: discovery,
            factory: factory,
            snapshotter: snapshotter,
            configStore: configStore
        )

        // 3. Подписка на IPC-активации прокси.
        ipc.startListening { [weak self] key in
            self?.handleProxyActivation(key: key)
        }

        // 3b. Обновление knownWindows из RefreshLoop.
        refreshLoop.onWindowsUpdated = { [weak self] map in
            self?.knownWindowsLock.lock()
            self?.knownWindows = map
            self?.knownWindowsLock.unlock()
        }

        // 4. Запуск refresh-цикла.
        refreshLoop.start()

        NSLog("WindowsWindows started. ProxyApps dir: \(configStore.proxyAppsURL.path)")
        DiagnosticJournal.shared.log("lifecycle", "started", fields: [
            "proxyAppsURL": configStore.proxyAppsURL.path,
            "axResolverAvailable": AXWindowIDResolver.shared.isAvailable,
            "accessibilityTrusted": AXIsProcessTrusted()
        ])
    }

    public func applicationWillTerminate(_ notification: Notification) {
        refreshLoop?.stop()
        ipc?.stopListening()
        factory?.terminateAll()
        focusTracker?.stop()
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

    /// Обработка клика по прокси в Dock.
    /// Прокси прислал windowKey → находим окно в knownWindows → toggle.
    private func handleProxyActivation(key: WindowKey) {
        let wasFocusedBeforeProxy = focusTracker.wasFocusedImmediatelyBeforeProxy(key)
        DiagnosticJournal.shared.log("ipc", "proxy_clicked", fields: [
            "key": key.stringValue,
            "wasFocusedBeforeProxy": wasFocusedBeforeProxy
        ])
        knownWindowsLock.lock()
        let window = knownWindows[key]
        knownWindowsLock.unlock()

        guard let window = window else {
            // Окно могло исчезнуть между кликом и обработкой. Пытаемся
            // найти его в свежем discovery.
            let config = (try? configStore.load()) ?? .default
            let fresh = discovery.discover(config: config)
            if let found = fresh.first(where: { $0.key == key }) {
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
            return
        }
        windowController.toggle(
            window: window,
            wasFocusedBeforeProxy: wasFocusedBeforeProxy
        )
    }
}
