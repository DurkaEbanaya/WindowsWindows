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
    private var lastCaptureAuthorization: Bool?
    private var snapshotInterval: TimeInterval = 5.0
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
        let config = (try? configStore.load()) ?? .default
        snapshotInterval = config.snapshotInterval

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: config.refreshInterval)
        timer.setEventHandler { [weak self] in
            Task { await self?.beginTickIfIdle() }
        }
        timer.resume()
        self.timer = timer
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
        let config = (try? configStore.load()) ?? .default
        return discovery.discover(config: config).first(where: { $0.key == key })
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
    }

    private func performTick() async {
        let config = (try? configStore.load()) ?? .default
        snapshotInterval = config.snapshotInterval

        let windows = discovery.discover(config: config)
        let windowMap = Dictionary(uniqueKeysWithValues: windows.map { ($0.key, $0) })
        let validKeys = Set(windowMap.keys)
        let captureAuthorized = await snapshotter.isCaptureAuthorized

        if lastCaptureAuthorization != captureAuthorized {
            lastCaptureAuthorization = captureAuthorized
            DiagnosticJournal.shared.log("snapshot", "authorization_changed", fields: [
                "authorized": captureAuthorized
            ])
        }

        if let callback = onWindowsUpdated {
            Task { @MainActor in callback(windowMap) }
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

        let staleKeys = Set(factory.existingProxyKeys()).subtracting(validKeys)
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
}
