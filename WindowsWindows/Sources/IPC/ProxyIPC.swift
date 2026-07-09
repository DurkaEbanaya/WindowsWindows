import Foundation

/// IPC между прокси-бандлами и main app.
///
/// Long-lived proxy reads `WWWindowKey` from Info.plist and remains running so
/// Dock keeps its tile visible. Each Dock activation sends a distributed
/// notification with that key; the proxy exits only when the real window dies.
/// Main app слушает эти уведомления и вызывает WindowController.toggle().
///
/// Используем `DistributedNotificationCenter` — работает между процессами
/// без настройки XPC-сервера, достаточно для одностороннего сообщения
/// "пользователь кликнул на прокси с этим windowKey".
public final class ProxyIPC {

    public static let notificationName = "com.windowswindows.proxy.activated"
    public static let windowKeyUserInfoKey = "windowKey"

    private let center: DistributedNotificationCenter

    public init() {
        self.center = DistributedNotificationCenter.default()
    }

    /// Отправить уведомление об активации прокси.
    /// Вызывается из прокси-бинаря.
    public func broadcastActivation(windowKey: String) {
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

    /// Начать слушать активации прокси. Вызывается из main app.
    /// - Parameter handler: вызывается на main thread с распарсенным WindowKey.
    public func startListening(handler: @escaping (WindowKey) -> Void) {
        center.addObserver(
            forName: Notification.Name(Self.notificationName),
            object: nil,
            queue: .main
        ) { note in
            guard let userInfo = note.userInfo,
                  let keyStr = userInfo[Self.windowKeyUserInfoKey] as? String,
                  let key = WindowKey(stringValue: keyStr) else {
                return
            }
            handler(key)
        }
    }

    public func stopListening() {
        center.removeObserver(self, name: Notification.Name(Self.notificationName), object: nil)
    }
}
