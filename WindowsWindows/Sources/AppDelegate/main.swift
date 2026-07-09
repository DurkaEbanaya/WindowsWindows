import Foundation
import Cocoa
import ApplicationServices

/// Главная точка входа. Создаёт NSApplication и делегирует AppDelegate.
@main
struct WindowsWindowsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
