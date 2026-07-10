import Foundation

/// One-way activation IPC from long-lived proxy applications to the main app.
@MainActor
public final class ProxyIPC {
    public static let notificationName = "com.windowswindows.proxy.activated"
    public static let windowKeyUserInfoKey = "windowKey"

    private let center = DistributedNotificationCenter.default()
    private var activationHandler: (@MainActor @Sendable (WindowKey) -> Void)?

    public init() {}

    public func broadcastActivation(windowKey: String) {
        center.postNotificationName(
            Notification.Name(Self.notificationName),
            object: nil,
            userInfo: [Self.windowKeyUserInfoKey: windowKey],
            deliverImmediately: true
        )
    }

    public func startListening(handler: @escaping @MainActor @Sendable (WindowKey) -> Void) {
        activationHandler = handler
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
        activationHandler = nil
    }

    @objc private func receivedActivation(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyString = userInfo[Self.windowKeyUserInfoKey] as? String,
              let key = WindowKey(stringValue: keyString) else {
            return
        }
        activationHandler?(key)
    }
}
