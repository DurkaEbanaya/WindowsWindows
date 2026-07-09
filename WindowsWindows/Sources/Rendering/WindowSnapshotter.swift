import Foundation
import Cocoa
import ScreenCaptureKit
import CoreGraphics

/// Снятие снапшотов окон через ScreenCaptureKit.
///
/// Требует **Screen Recording permission** (TCC). Без него captureImage
/// вернёт ошибку `-3801`. Permission запрашивается системой автоматически
/// при первом вызове SCShareableContent / captureImage.
///
/// Архитектура:
/// - `capture(window:)` — делает один снапшот окна по windowID.
/// - `NSImage` кэшируется на короткое время (snapshotInterval из конфига),
///   чтобы не дёргать SCK на каждом refresh.
/// - `SCShareableContent` пере-запрашивается раз в N секунд (он дорогой).
public final class WindowSnapshotter {

    /// Размер превью (ширина × высота). Dock tile ≈ 64pt, берём с запасом
    /// для retina (×2). Пропорции сохраняются.
    public static let previewWidth = 128
    public static let previewHeight = 96

    /// Интервал обновления SCShareableContent (дорогой вызов).
    private static let contentRefreshInterval: TimeInterval = 5.0

    private var content: SCShareableContent?
    private var contentFetchedAt: Date = .distantPast
    private let cache = NSCache<NSNumber, NSImage>()
    private let queue = DispatchQueue(label: "com.windowswindows.snapshotter", qos: .utility)

    public init() {
        cache.countLimit = 100
    }

    /// Сделать снапшот окна. Асинхронный — SCK не имеет sync API.
    ///
    /// - Parameter windowID: CGWindowID целевого окна.
    /// - Returns: NSImage превью или nil (нет permission / окно исчезло / ошибка).
    public func capture(windowID: CGWindowID) async -> NSImage? {
        // Кэш: если свежий — вернуть.
        if let cached = cache.object(forKey: NSNumber(value: windowID)) {
            return cached
        }

        guard let content = await getFreshContent() else { return nil }
        guard let target = findWindow(id: windowID, in: content) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Self.previewWidth
        config.height = Self.previewHeight
        config.showsCursor = false
        config.captureResolution = .best

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            let image = NSImage(cgImage: cgImage, size: NSSize(
                width: Self.previewWidth,
                height: Self.previewHeight
            ))
            cache.setObject(image, forKey: NSNumber(value: windowID))
            return image
        } catch {
            // -3801 = no permission; другие = окно исчезло/недоступно.
            return nil
        }
    }

    /// Сбросить кэш для конкретного окна (например, при смене title —
    /// превью могло измениться).
    public func invalidate(windowID: CGWindowID) {
        cache.removeObject(forKey: NSNumber(value: windowID))
    }

    /// Сбросить весь кэш.
    public func invalidateAll() {
        cache.removeAllObjects()
    }

    // MARK: - Internal

    private func getFreshContent() async -> SCShareableContent? {
        let now = Date()
        if let content = content, now.timeIntervalSince(contentFetchedAt) < Self.contentRefreshInterval {
            return content
        }
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false  // нужны минимизированные тоже для icon refresh
            )
            self.content = c
            self.contentFetchedAt = now
            return c
        } catch {
            return nil
        }
    }

    private func findWindow(id: CGWindowID, in content: SCShareableContent) -> SCWindow? {
        content.windows.first(where: { $0.windowID == id })
    }
}
