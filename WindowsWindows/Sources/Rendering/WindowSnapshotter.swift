import Foundation
import Cocoa
import ScreenCaptureKit
import CoreGraphics

/// Снятие снапшотов окон через ScreenCaptureKit.
///
/// Требует **Screen Recording permission** (TCC). На macOS 26 приложение
/// должно явно вызвать `CGRequestScreenCaptureAccess`; если система не может
/// показать prompt, пользователь добавляет bundle в Privacy & Security.
///
/// Архитектура:
/// - `capture(windowID:)` — делает один снапшот окна по windowID.
/// - `SCShareableContent` пере-запрашивается раз в N секунд (он дорогой).
/// Actor isolation сериализует доступ к кэшу ScreenCaptureKit content.
public actor WindowSnapshotter {

    /// Размер превью (ширина × высота). Dock tile ≈ 64pt, берём с запасом
    /// для retina (×2). Пропорции сохраняются.
    public static let maximumPreviewDimension = 512

    /// Интервал обновления SCShareableContent (дорогой вызов).
    private static let contentRefreshInterval: TimeInterval = 5.0

    private var content: SCShareableContent?
    private var contentFetchedAt: Date = .distantPast
    public init() {}

    public var isCaptureAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public enum CaptureError: LocalizedError {
        case contentUnavailable(String)
        case windowUnavailable(CGWindowID)
        case screenshotFailed(String)

        public var errorDescription: String? {
            switch self {
            case .contentUnavailable(let message):
                return "ScreenCaptureKit content unavailable: \(message)"
            case .windowUnavailable(let id):
                return "Window \(id) is absent from ScreenCaptureKit content"
            case .screenshotFailed(let message):
                return "Window screenshot failed: \(message)"
            }
        }
    }

    /// Сделать снапшот окна. Асинхронный — SCK не имеет sync API.
    ///
    /// - Parameter windowID: CGWindowID целевого окна.
    /// - Returns: NSImage превью.
    /// - Throws: typed capture error when content or the target is unavailable.
    public func capture(windowID: CGWindowID) async throws -> NSImage {
        let content = try await getFreshContent()
        guard let target = findWindow(id: windowID, in: content) else {
            throw CaptureError.windowUnavailable(windowID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let size = previewSize(for: target.frame.size)
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        config.captureResolution = .best

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(cgImage: cgImage, size: NSSize(width: size.width, height: size.height))
        } catch {
            throw CaptureError.screenshotFailed(error.localizedDescription)
        }
    }

    // MARK: - Internal

    private func getFreshContent() async throws -> SCShareableContent {
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
            throw CaptureError.contentUnavailable(error.localizedDescription)
        }
    }

    private func findWindow(id: CGWindowID, in content: SCShareableContent) -> SCWindow? {
        content.windows.first(where: { $0.windowID == id })
    }

    private func previewSize(for source: CGSize) -> (width: Int, height: Int) {
        guard source.width > 0, source.height > 0 else {
            return (Self.maximumPreviewDimension, Self.maximumPreviewDimension)
        }
        let scale = min(
            CGFloat(Self.maximumPreviewDimension) / source.width,
            CGFloat(Self.maximumPreviewDimension) / source.height
        )
        return (
            max(1, Int((source.width * scale).rounded())),
            max(1, Int((source.height * scale).rounded()))
        )
    }
}
