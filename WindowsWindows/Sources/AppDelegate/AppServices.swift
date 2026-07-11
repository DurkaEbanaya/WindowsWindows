import Carbon
import Foundation
import ServiceManagement

public enum MainAppCommandIPC {
    public static let openSettingsNotificationName = Notification.Name("com.windowswindows.main.open-settings")

    public static func requestOpenSettings() {
        DistributedNotificationCenter.default().postNotificationName(
            openSettingsNotificationName,
            object: Bundle.main.bundleIdentifier,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

public enum ProfileTraversalDirection: Sendable {
    case previous
    case next
}

public final class GlobalHotKeyController: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let callback: @MainActor @Sendable (ProfileTraversalDirection) -> Void
        init(_ callback: @escaping @MainActor @Sendable (ProfileTraversalDirection) -> Void) {
            self.callback = callback
        }
    }

    private var eventHandler: EventHandlerRef?
    private var previousHotKey: EventHotKeyRef?
    private var nextHotKey: EventHotKeyRef?
    private var callbackBox: CallbackBox?

    public init() {}
    deinit { stop() }

    public func apply(
        config: WorkspaceHotKeyConfig,
        callback: @escaping @MainActor @Sendable (ProfileTraversalDirection) -> Void
    ) {
        stop()
        guard config.isEnabled else { return }
        let box = CallbackBox(callback)
        callbackBox = box
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(box).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            let direction: ProfileTraversalDirection? = hotKeyID.id == 1 ? .previous : (hotKeyID.id == 2 ? .next : nil)
            if let direction {
                let callback = box.callback
                Task { @MainActor in callback(direction) }
            }
            return noErr
        }, 1, &eventType, userData, &eventHandler)

        previousHotKey = register(id: 1, shortcut: config.previous)
        nextHotKey = register(id: 2, shortcut: config.next)
    }

    public func stop() {
        if let previousHotKey { UnregisterEventHotKey(previousHotKey) }
        if let nextHotKey { UnregisterEventHotKey(nextHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        previousHotKey = nil
        nextHotKey = nil
        eventHandler = nil
        callbackBox = nil
    }

    private func register(id: UInt32, shortcut: KeyboardShortcut) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x57574B59), id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            DiagnosticJournal.shared.log("hotkey", "registration_failed", fields: ["id": id, "status": status])
        }
        return ref
    }
}

public enum LoginItemService {
    @MainActor
    public static func apply(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            DiagnosticJournal.shared.log("login_item", "applied", fields: [
                "enabled": enabled,
                "status": String(describing: SMAppService.mainApp.status)
            ])
        } catch {
            DiagnosticJournal.shared.log("login_item", "apply_failed", fields: [
                "enabled": enabled,
                "error": error.localizedDescription
            ])
        }
    }
}

public final class UpdateCheckService: @unchecked Sendable {
    public init() {}

    public func check(config: WorkspaceUpdateConfig) async {
        guard config.automaticallyChecksForUpdates else { return }
        do {
            var request = URLRequest(url: config.releasesAPIURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard 200..<300 ~= status else {
                DiagnosticJournal.shared.log("update", "feed_check_failed", fields: [
                    "url": config.releasesAPIURL.absoluteString,
                    "status": status
                ])
                return
            }
            DiagnosticJournal.shared.log("update", "feed_check_succeeded", fields: [
                "url": config.releasesAPIURL.absoluteString,
                "bytes": data.count
            ])
        } catch {
            DiagnosticJournal.shared.log("update", "feed_check_failed", fields: [
                "url": config.releasesAPIURL.absoluteString,
                "error": error.localizedDescription
            ])
        }
    }
}
