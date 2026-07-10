import Foundation

/// Политика допуска приложений к отслеживанию.
///
/// Иерархия (от высшего приоритета к низшему):
/// 1. `systemExclusions` — hardcoded список системных процессов, которые
///    **никогда** не отслеживаются, независимо от пользовательского конфига.
///    Это защита от зацикливания (прокси для Dock.app → бесконечный цикл
///    refresh) и от визуального мусора (LoginWindow, SystemUIServer).
/// 2. Пользовательский конфиг (`ShelfConfig`):
///    - `allExceptListed`: отслеживать всё, что не в systemExclusions и не в
///      пользовательском списке.
///    - `onlyListed`: отслеживать только то, что в пользовательском списке
///      и не в systemExclusions.
public enum Policy {
    /// Системные bundle identifiers, которые **всегда** исключаются.
    /// Это baseline, который пользователь не может обойти через конфиг.
    public static let systemExclusions: Set<String> = [
        "com.apple.dock",
        "com.apple.systempreferences",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.loginwindow",
        "com.apple.finder",            // Finder windows — обычно мусор для shelf
        "com.apple.WindowManager",
        "com.apple.appkit.xctoolchain",
        // Capture overlays create short-lived utility windows, not user documents.
        "pl.maketheweb.cleanshotx",
        // Собственный bundle id — чтобы не отслеживать свои же прокси и main app.
        "com.windowswindows.app",
        // Прокси-бандлы имеют префикс; отдельная проверка в Policy.admit
    ]

    /// Префикс bundle id для генерируемых прокси-приложений.
    public static let proxyBundlePrefix = "com.windowswindows.proxy."

    /// Проверить, должен ли приложение с данным bundle id отслеживаться.
    public static func admit(bundleIdentifier: String?, config: ShelfConfig) -> Bool {
        guard let bid = bundleIdentifier, !bid.isEmpty else {
            return false
        }
        // `com.apple.*` is the system application/helper namespace. The product
        // contract is "all non-system applications", so system helpers must not
        // reach AX discovery at all.
        if bid.hasPrefix("com.apple.") {
            return false
        }
        // 1. Системные исключения — всегда блокируют.
        if systemExclusions.contains(bid) {
            return false
        }
        // 2. Прокси-бандлы никогда не отслеживаются (защита от рекурсии).
        if bid.hasPrefix(proxyBundlePrefix) {
            return false
        }
        // 3. Пользовательский конфиг.
        switch config.scopeMode {
        case .allExceptListed:
            // Отслеживать всё, кроме списка (системные уже отфильтрованы выше).
            return !config.bundleIdentifiers.contains(bid)
        case .onlyListed:
            return config.bundleIdentifiers.contains(bid)
        }
    }

    /// Проверить, является ли bundle id прокси-приложением WindowsWindows.
    public static func isProxyBundle(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.hasPrefix(proxyBundlePrefix)
    }

    /// Whether an application can be placed in the user-managed scope list.
    /// Hard exclusions are policy, not editable configuration.
    public static func isUserConfigurable(bundleIdentifier: String) -> Bool {
        !bundleIdentifier.isEmpty
            && !bundleIdentifier.hasPrefix("com.apple.")
            && !systemExclusions.contains(bundleIdentifier)
            && !isProxyBundle(bundleIdentifier)
    }
}
