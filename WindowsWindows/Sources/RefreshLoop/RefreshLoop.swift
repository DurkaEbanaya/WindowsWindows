import Foundation
import Cocoa

/// Periodically reconciles proxy bundles with the set of real windows.
/// All mutable reconciliation state is actor-isolated, so capture operations
/// from adjacent timer events can never overlap.
public actor RefreshLoop {
    private let discovery: WindowDiscovery
    private let factory: ProxyFactory
    private let snapshotter: WindowSnapshotter
    private let configStore: ConfigStore

    private var timer: DispatchSourceTimer?
    private var tickTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var lastSnapshotTimes: [WindowKey: Date] = [:]
    private var lastTitles: [WindowKey: String] = [:]
    private var lastKnownWindows: [WindowKey: ObservedWindow] = [:]
    private var lastCaptureAuthorization: Bool?
    private var refreshInterval: TimeInterval = 2.0
    private var snapshotInterval: TimeInterval = 5.0
    private var lastKnownConfig: ShelfConfig?
    private var onWindowsUpdated: (@MainActor @Sendable ([WindowKey: ObservedWindow]) -> Void)?

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
        guard timer == nil, !isShuttingDown else { return }
        if let config = loadConfig() {
            refreshInterval = config.refreshInterval
            snapshotInterval = config.snapshotInterval
        }
        scheduleNextTick(after: 0)
    }

    public func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        timer?.cancel()
        timer = nil
        let activeTick = tickTask
        activeTick?.cancel()
        await activeTick?.value
        tickTask = nil
    }

    public func tick() {
        beginTickIfIdle()
    }

    public func setOnWindowsUpdated(
        _ callback: @escaping @MainActor @Sendable ([WindowKey: ObservedWindow]) -> Void
    ) {
        onWindowsUpdated = callback
    }

    public func resolveWindow(key: WindowKey) -> ObservedWindow? {
        let config = loadConfig()
        guard let config else { return nil }
        let snapshot = discovery.discover(config: config)
        reconcileKnownWindows(with: snapshot)
        return lastKnownWindows[key]
    }

    private func beginTickIfIdle() {
        guard tickTask == nil, !isShuttingDown else { return }
        tickTask = Task { [weak self] in
            await self?.performTick()
            await self?.tickDidFinish()
        }
    }

    private func tickDidFinish() {
        tickTask = nil
        guard !isShuttingDown else { return }
        scheduleNextTick(after: refreshInterval)
    }

    private func performTick() async {
        let config = loadConfig()
        guard let config else { return }
        refreshInterval = config.refreshInterval
        snapshotInterval = config.snapshotInterval

        let discoverySnapshot = discovery.discover(config: config)
        let windows = discoverySnapshot.windows
        let windowMap = Dictionary(uniqueKeysWithValues: windows.map { ($0.key, $0) })
        let validKeys = Set(windowMap.keys)
        reconcileKnownWindows(with: discoverySnapshot)
        let captureAuthorized = await snapshotter.isCaptureAuthorized

        if lastCaptureAuthorization != captureAuthorized {
            lastCaptureAuthorization = captureAuthorized
            DiagnosticJournal.shared.log("snapshot", "authorization_changed", fields: [
                "authorized": captureAuthorized
            ])
        }

        if let callback = onWindowsUpdated {
            let knownWindows = lastKnownWindows
            Task { @MainActor in callback(knownWindows) }
        }

        for window in windows {
            guard !Task.isCancelled else { return }
            do {
                let shouldSnapshot = captureAuthorized && shouldRefreshSnapshot(for: window)
                let snapshot: NSImage?
                if shouldSnapshot {
                    do {
                        snapshot = try await snapshotter.capture(windowID: window.windowNumber)
                    } catch {
                        snapshot = nil
                        DiagnosticJournal.shared.log("snapshot", "capture_failed", fields: [
                            "windowID": window.windowNumber,
                            "error": error.localizedDescription
                        ])
                    }
                } else {
                    snapshot = nil
                }

                guard !Task.isCancelled else { return }
                try factory.ensure(window: window, snapshot: snapshot)
                lastTitles[window.key] = window.title
                if snapshot != nil {
                    lastSnapshotTimes[window.key] = Date()
                }
            } catch {
                NSLog("ProxyFactory.ensure failed for \(window.key.stringValue): \(error.localizedDescription)")
            }
        }

        do {
            try factory.removeInvalidProxyBundles()
        } catch {
            NSLog("ProxyFactory.removeInvalidProxyBundles failed: \(error.localizedDescription)")
        }
        let staleKeys = factory.existingProxies().filter { proxy in
            return !validKeys.contains(proxy.key)
                && discoverySnapshot.isAbsenceAuthoritative(
                    for: proxy.key,
                    persistedProcessIdentity: proxy.processIdentity
                )
        }.map(\.key)
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

    private func shouldRefreshSnapshot(for window: ObservedWindow) -> Bool {
        if lastTitles[window.key] != window.title {
            return true
        }
        if let last = lastSnapshotTimes[window.key],
           Date().timeIntervalSince(last) < snapshotInterval {
            return false
        }
        return true
    }

    private func reconcileKnownWindows(with snapshot: WindowDiscoverySnapshot) {
        let currentKeys = Set(snapshot.windows.map(\.key))
        let removedKeys = Set(lastKnownWindows.keys).subtracting(currentKeys).filter {
            guard let window = lastKnownWindows[$0] else { return true }
            return snapshot.isAbsenceAuthoritative(
                for: window.key,
                persistedProcessIdentity: window.processIdentity
            )
        }
        for key in removedKeys {
            lastKnownWindows.removeValue(forKey: key)
        }
        for window in snapshot.windows {
            lastKnownWindows[window.key] = window
        }
    }

    private func loadConfig() -> ShelfConfig? {
        do {
            let config = try configStore.load()
            lastKnownConfig = config
            return config
        } catch {
            DiagnosticJournal.shared.log("config", "load_failed", fields: [
                "path": configStore.configURL.path,
                "error": error.localizedDescription
            ])
            return lastKnownConfig
        }
    }

    private func scheduleNextTick(after delay: TimeInterval) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { await self?.timerFired() }
        }
        timer.resume()
        self.timer = timer
    }

    private func timerFired() {
        timer?.cancel()
        timer = nil
        beginTickIfIdle()
    }
}
