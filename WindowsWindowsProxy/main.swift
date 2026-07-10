import Foundation
import Cocoa
import Darwin

/// Точка входа прокси-бандла.
///
/// Жизненный цикл прокси:
/// 1. Main app запускает прокси как процесс (`open` / NSWorkspace.open).
/// 2. Прокси стартует NSApplication с activation policy `.accessory`
///    (LSUIElement=true) — он running, в Dock появляется tile, но нет
///    menu bar / cmd-tab entry.
/// 3. При клике на tile в Dock macOS активирует прокси-процесс.
///    AppDelegate.applicationDidBecomeActive ловит это и отправляет
///    distributed notification с WWWindowKey.
/// 4. После отправки прокси НЕ завершается — он продолжает жить,
///    чтобы tile оставался в Dock. Activation policy возвращается в
///    `.accessory`, чтобы фокус ушёл на реальное окно (main app поднимет его).
/// 5. Когда реальное окно исчезает, main app терминирует прокси-процесс
///    через NSRunningApplication.terminate → tile исчезает.
///
/// Имена notification/userInfo захардкожены здесь (и в ProxyIPC.swift main app)
/// намеренно — прокси-бинарь не должен тащить зависимости от main app target.
@main
struct WindowsWindowsProxyMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = ProxyAppDelegate()
        app.delegate = delegate
        // Не вызываем setActivationPolicy(.accessory) — это превратит нас в
        // UIElement app, и Dock НЕ покажет tile.
        // Оставляем default .regular (Foreground) — Dock показывает tile для
        // running Foreground apps. Menu bar / cmd-tab присутствуют, но прокси
        // сразу прячется после запуска через NSApp.hide, и не крадёт фокус
        // при последующих кликах (applicationDidBecomeActive сразу hide + broadcast).
        app.run()
    }
}

@MainActor
final class ProxyAppDelegate: NSObject, NSApplicationDelegate {
    // Синхронизировать с ProxyIPC.swift (main app).
    private static let notificationName = "com.windowswindows.proxy.activated"
    private static let previewUpdatedNotificationName = "com.windowswindows.proxy.preview-updated"
    private static let windowKeyUserInfoKey = "windowKey"
    private static let previewFileName = "preview.png"

    private let windowKey: String
    private let mainPID: pid_t
    private var ownerWatchdog: Timer?
    private var lastActivationTime: Date = .distantPast
    private var pendingActivation = false
    private static let debounceInterval: TimeInterval = 0.3

    override init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "WWWindowKey") as? String ?? ""
        let ownerPID = Bundle.main.object(forInfoDictionaryKey: "WWMainPID") as? Int ?? 0
        self.windowKey = key
        self.mainPID = pid_t(ownerPID)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if windowKey.isEmpty || mainPID <= 0 {
            NSApp.terminate(nil)
            return
        }
        updateDockPreview()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(previewUpdated(_:)),
            name: Notification.Name(Self.previewUpdatedNotificationName),
            object: windowKey
        )

        // Tile остаётся в Dock (running Foreground app).
        NSApp.hide(nil)
        ownerWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if kill(self.mainPID, 0) == -1 && errno == ESRCH {
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// macOS активировала прокси → пользователь кликнул на tile в Dock.
    func applicationDidBecomeActive(_ notification: Notification) {
        let now = Date()
        NSApp.hide(nil)
        if now.timeIntervalSince(lastActivationTime) < Self.debounceInterval {
            return
        }
        lastActivationTime = now
        pendingActivation = true
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard pendingActivation else { return }
        pendingActivation = false
        broadcastActivation()
    }

    @objc private func previewUpdated(_ notification: Notification) {
        updateDockPreview()
    }

    private func updateDockPreview() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(Self.previewFileName),
              let image = NSImage(contentsOf: url) else {
            return
        }
        NSApp.applicationIconImage = image
    }

    private func broadcastActivation() {
        let center = DistributedNotificationCenter.default()
        let userInfo: [String: Any] = [
            Self.windowKeyUserInfoKey: windowKey
        ]
        center.postNotificationName(
            Notification.Name(Self.notificationName),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}
