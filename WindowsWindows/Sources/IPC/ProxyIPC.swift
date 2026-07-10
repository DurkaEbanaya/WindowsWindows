import Foundation

/// One-way activation IPC from long-lived proxy applications to the main app.
public enum ProxyIPCAction: String, Sendable {
    case activate
    case close
}

public struct ProxyIPCMessage: Equatable, Sendable {
    public let action: ProxyIPCAction
    public let windowKey: WindowKey

    public init(action: ProxyIPCAction, windowKey: WindowKey) {
        self.action = action
        self.windowKey = windowKey
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let keyString = userInfo[ProxyIPC.windowKeyUserInfoKey] as? String,
              let key = WindowKey(stringValue: keyString) else {
            return nil
        }

        let action: ProxyIPCAction
        if let rawAction = userInfo[ProxyIPC.actionUserInfoKey] as? String {
            guard let parsed = ProxyIPCAction(rawValue: rawAction) else { return nil }
            action = parsed
        } else {
            // Backward compatibility: v0.3 and older proxy bundles sent only a
            // windowKey. That message has always meant Dock tile activation.
            action = .activate
        }

        self.init(action: action, windowKey: key)
    }
}

@MainActor
public final class ProxyIPC {
    public nonisolated static let notificationName = "com.windowswindows.proxy.activated"
    public nonisolated static let windowKeyUserInfoKey = "windowKey"
    public nonisolated static let actionUserInfoKey = "action"

    private let center = DistributedNotificationCenter.default()
    private var messageHandler: (@MainActor @Sendable (ProxyIPCMessage) -> Void)?

    public init() {}

    public func broadcastActivation(windowKey: String) {
        broadcast(action: .activate, windowKey: windowKey)
    }

    public func broadcastCloseRequest(windowKey: String) {
        broadcast(action: .close, windowKey: windowKey)
    }

    public func broadcast(action: ProxyIPCAction, windowKey: String) {
        center.postNotificationName(
            Notification.Name(Self.notificationName),
            object: nil,
            userInfo: [
                Self.windowKeyUserInfoKey: windowKey,
                Self.actionUserInfoKey: action.rawValue,
            ],
            deliverImmediately: true
        )
    }

    public func startListening(handler: @escaping @MainActor @Sendable (ProxyIPCMessage) -> Void) {
        messageHandler = handler
        center.addObserver(
            self,
            selector: #selector(receivedActivation(_:)),
            name: Notification.Name(Self.notificationName),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    public func stopListening() {
        center.removeObserver(self, name: Notification.Name(Self.notificationName), object: nil)
        messageHandler = nil
    }

    @objc private func receivedActivation(_ notification: Notification) {
        guard let message = ProxyIPCMessage(userInfo: notification.userInfo) else { return }
        messageHandler?(message)
    }
}
