import Foundation
import Cocoa

/// Периодический цикл синхронизации прокси-бандлов с реальными окнами.
///
/// На каждом тике (по умолчанию каждые 2с):
/// 1. `WindowDiscovery.discover()` — получить текущие окна.
/// 2. Для новых окон (нет прокси) — создать прокси + снапшот.
/// 3. Для существующих — обновить, если изменился title или прошла
///    `snapshotInterval` с последнего снимка.
/// 4. Удалить прокси для исчезнувших окон.
/// 5. Очистить дисковые прокси-бандлы без соответствующих окон.
///
/// Rekeying: окно с изменившимся wid = новый прокси. Старый удаляется
/// (если его wid не появился в новом списке). Это by design —
/// "склеивание" окон через эвристику хрупко и ведёт к гонкам.
public final class RefreshLoop {

    private let discovery: WindowDiscovery
    private let factory: ProxyFactory
    private let snapshotter: WindowSnapshotter
    private let configStore: ConfigStore

    private var timer: DispatchSourceTimer?
    private var lastSnapshotTimes: [WindowKey: Date] = [:]
    private var lastTitles: [WindowKey: String] = [:]

    /// Интервал превью-обновления. Берётся из конфига, но cached здесь
    /// чтобы не дёргать диск на каждом тике.
    private var snapshotInterval: TimeInterval = 5.0

    /// Callback: обновлённый список текущих окон. Вызывается на main thread
    /// после каждого тика. AppDelegate использует это для IPC-обработки.
    public var onWindowsUpdated: (([WindowKey: ObservedWindow]) -> Void)?

    public init(
        discovery: WindowDiscovery,
        factory: ProxyFactory,
        snapshotter: WindowSnapshotter,
        configStore: ConfigStore
    ) {
        self.discovery = discovery
        self.factory = factory
        self.snapshotter = snapshotter
        self.configStore = configStore
    }

    public func start() {
        guard timer == nil else { return }
        let config = (try? configStore.load()) ?? .default
        snapshotInterval = config.snapshotInterval

        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: config.refreshInterval)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        self.timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Один цикл синхронизации. Публичный для возможности ручного вызова
    /// (например, после изменения конфига).
    public func tick() {
        let config = (try? configStore.load()) ?? .default
        snapshotInterval = config.snapshotInterval

        let windows = discovery.discover(config: config)
        let windowMap = Dictionary(uniqueKeysWithValues: windows.map { ($0.key, $0) })
        let validKeys = Set(windowMap.keys)

        // 0. Опубликовать текущий snapshot окон для IPC-обработчика.
        if let cb = onWindowsUpdated {
            DispatchQueue.main.async { cb(windowMap) }
        }

        // 1. Создать / обновить прокси для существующих окон.
        for window in windows {
            do {
                let shouldSnapshot = shouldRefreshSnapshot(for: window)
                let snapshot: NSImage? = shouldSnapshot
                    ? awaitSyncSnapshot(windowID: window.windowNumber)
                    : nil
                try factory.ensure(window: window, snapshot: snapshot)
                lastTitles[window.key] = window.title
                if shouldSnapshot {
                    lastSnapshotTimes[window.key] = Date()
                }
            } catch {
                // Логировать, но не падать — один сломанный прокси не должен
                // останавливать весь цикл.
                NSLog("ProxyFactory.ensure failed for \(window.key.stringValue): \(error.localizedDescription)")
            }
        }

        // 2. Удалить прокси для исчезнувших окон.
        let existingKeys = Set(factory.existingProxyKeys())
        let staleKeys = existingKeys.subtracting(validKeys)
        for key in staleKeys {
            do {
                try factory.remove(windowKey: key)
            } catch {
                NSLog("ProxyFactory.remove failed for \(key.stringValue): \(error.localizedDescription)")
            }
            lastSnapshotTimes.removeValue(forKey: key)
            lastTitles.removeValue(forKey: key)
        }
    }

    // MARK: - Internal

    private func shouldRefreshSnapshot(for window: ObservedWindow) -> Bool {
        // Title изменился → обязательно переснять.
        if lastTitles[window.key] != window.title {
            return true
        }
        // Прошёл snapshotInterval → переснять.
        if let last = lastSnapshotTimes[window.key],
           Date().timeIntervalSince(last) < snapshotInterval {
            return false
        }
        return true
    }

    /// Синхронно дождаться асинхронного снапшота.
    /// Использует semaphore — acceptable т.к. refresh идёт в utility-queue.
    private func awaitSyncSnapshot(windowID: CGWindowID) -> NSImage? {
        let sem = DispatchSemaphore(value: 0)
        var result: NSImage?
        Task {
            result = await snapshotter.capture(windowID: windowID)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3.0)
        return result
    }
}
