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

    public init?(userInfo: [AnyHashable: Any]?, expectedSessionToken: String) {
        guard let userInfo,
              let keyString = userInfo[ProxyIPC.windowKeyUserInfoKey] as? String,
              let key = WindowKey(stringValue: keyString),
              let sessionToken = userInfo[ProxyIPC.sessionTokenUserInfoKey] as? String,
              !expectedSessionToken.isEmpty,
              sessionToken == expectedSessionToken else {
            return nil
        }

        let action: ProxyIPCAction
        if let rawAction = userInfo[ProxyIPC.actionUserInfoKey] as? String {
            guard let parsed = ProxyIPCAction(rawValue: rawAction) else { return nil }
            action = parsed
        } else { return nil }

        self.init(action: action, windowKey: key)
    }
}

@MainActor
public final class ProxyIPC {
    public nonisolated static let notificationName = "com.windowswindows.proxy.activated"
    public nonisolated static let windowKeyUserInfoKey = "windowKey"
    public nonisolated static let actionUserInfoKey = "action"
    public nonisolated static let sessionTokenUserInfoKey = "sessionToken"

    private let center = DistributedNotificationCenter.default()
    private let sessionToken: String
    private var messageHandler: (@MainActor @Sendable (ProxyIPCMessage) -> Void)?

    public init(sessionToken: String) {
        self.sessionToken = sessionToken
    }

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
                Self.sessionTokenUserInfoKey: sessionToken,
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
        guard let message = ProxyIPCMessage(
            userInfo: notification.userInfo,
            expectedSessionToken: sessionToken
        ) else { return }
        messageHandler?(message)
    }
}
