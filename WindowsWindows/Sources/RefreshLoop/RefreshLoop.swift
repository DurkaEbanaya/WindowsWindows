import Foundation
import Cocoa

public struct CloseProxySuppressionState: Equatable, Sendable {
    public static let defaultDuration: TimeInterval = 4.0

    private var expirations: [WindowKey: Date] = [:]

    public init() {}

    public mutating func suppress(key: WindowKey, now: Date, duration: TimeInterval = Self.defaultDuration) {
        expirations[key] = now.addingTimeInterval(duration)
    }

    public mutating func isSuppressed(key: WindowKey, now: Date) -> Bool {
        guard let expiration = expirations[key] else { return false }
        if expiration <= now {
            expirations.removeValue(forKey: key)
            return false
        }
        return true
    }

    public mutating func removeObservedKeys(_ observedKeys: Set<WindowKey>, now: Date) {
        let keysToRemove = expirations.compactMap { key, expiration in
            expiration <= now || !observedKeys.contains(key) ? key : nil
        }
        for key in keysToRemove {
            expirations.removeValue(forKey: key)
        }
    }
}

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
    private var lastKnownWorkspace: WorkspaceConfig?
    private var onWindowsUpdated: (@MainActor @Sendable ([WindowKey: ObservedWindow]) -> Void)?
    private var closeSuppressions = CloseProxySuppressionState()

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
        if let workspace = loadWorkspace() {
            let config = workspace.effectiveShelfConfig
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
        let workspace = loadWorkspace()
        guard let workspace else { return nil }
        let config = workspace.effectiveShelfConfig
        let snapshot = discovery.discover(config: config)
        reconcileKnownWindows(with: snapshot)
        return lastKnownWindows[key]
    }

    public func suppressProxyLaunch(forCloseOf key: WindowKey) {
        closeSuppressions.suppress(key: key, now: Date())
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
        let workspace = loadWorkspace()
        guard var workspace else { return }
        let config = workspace.effectiveShelfConfig
        refreshInterval = config.refreshInterval
        snapshotInterval = config.snapshotInterval

        let discoverySnapshot = discovery.discover(config: config)
        let windows = discoverySnapshot.windows
        let windowMap = Dictionary(uniqueKeysWithValues: windows.map { ($0.key, $0) })
        let validKeys = Set(windowMap.keys)
        reconcileKnownWindows(with: discoverySnapshot)
        do {
            if try workspace.assignNewWindowsToActiveProfile(validKeys) {
                workspace = try configStore.updateWorkspace { stored in
                    try stored.assignNewWindowsToActiveProfile(validKeys)
                }
                lastKnownWorkspace = workspace
            }
        } catch {
            DiagnosticJournal.shared.log("workspace", "window_assignment_failed", fields: [
                "error": error.localizedDescription
            ])
        }
        let activeKeys = workspace.activeWindowKeySet()
        closeSuppressions.removeObservedKeys(validKeys, now: Date())
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

        for window in windows where activeKeys.contains(window.key) {
            guard !Task.isCancelled else { return }
            if closeSuppressions.isSuppressed(key: window.key, now: Date()) {
                DiagnosticJournal.shared.log("proxy", "launch_suppressed_for_close", fields: [
                    "key": window.key.stringValue
                ])
                continue
            }
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
        let projectedKeys = validKeys.intersection(activeKeys)
        let staleKeys = factory.existingProxies().filter { proxy in
            return !projectedKeys.contains(proxy.key)
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

    private func loadWorkspace() -> WorkspaceConfig? {
        do {
            let workspace = try configStore.loadWorkspace()
            let config = workspace.effectiveShelfConfig
            lastKnownWorkspace = workspace
            lastKnownConfig = config
            return workspace
        } catch {
            DiagnosticJournal.shared.log("config", "load_failed", fields: [
                "path": configStore.configURL.path,
                "error": error.localizedDescription
            ])
            if let lastKnownWorkspace { return lastKnownWorkspace }
            return lastKnownConfig.map { config in
                WorkspaceConfig(profiles: [
                    WorkspaceProfile(id: WorkspaceConfig.defaultProfileID, name: "Default", shelfConfig: config)
                ])
            }
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
