import Cocoa
import CoreGraphics

@MainActor
public final class DockHoverPreviewController {
    private struct Item {
        let window: ObservedWindow
        let preview: NSImage?
        let appIcon: NSImage?
    }

    private let resolver = DockItemResolver()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var panel: DockHoverPreviewPanel?
    private var items: [Item] = []
    private var shownTarget: DockItemTarget?
    private var pendingTarget: DockItemTarget?
    private var pendingWorkItem: DispatchWorkItem?
    private var hitTestWorkItem: DispatchWorkItem?
    private var windowsProvider: ((DockItemTarget) -> [ObservedWindow])?
    private var previewProvider: ((WindowKey) -> NSImage?)?
    private var activationHandler: ((ObservedWindow) -> Void)?
    public var isEnabled = false {
        didSet { if !isEnabled { hide() } }
    }
    public var showDelay: TimeInterval = WorkspaceBehaviorConfig.defaultDockHoverPreviewDelay

    public init() {}

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    public func start(
        windows: @escaping (DockItemTarget) -> [ObservedWindow],
        preview: @escaping (WindowKey) -> NSImage?,
        activate: @escaping (ObservedWindow) -> Void
    ) {
        stop()
        windowsProvider = windows
        previewProvider = preview
        activationHandler = activate
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<DockHoverPreviewController>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { controller.handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            DiagnosticJournal.shared.log("dock_hover", "event_tap_registration_failed")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        hide()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        windowsProvider = nil
        previewProvider = nil
        activationHandler = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            hide()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard type == .mouseMoved, isEnabled else { return }
        let point = event.location
        if panel?.frame.insetBy(dx: -8, dy: -8).contains(NSScreenPoint.fromQuartz(point)) == true {
            pendingWorkItem?.cancel()
            return
        }
        guard resolver.isNearDock(point) else {
            hitTestWorkItem?.cancel()
            if shownTarget != nil || pendingTarget != nil { scheduleHide() }
            return
        }
        hitTestWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.resolveTarget(at: point) }
        hitTestWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func resolveTarget(at point: CGPoint) {
        hitTestWorkItem = nil
        let target = resolver.target(at: point)
        if target == shownTarget {
            pendingWorkItem?.cancel()
            return
        }
        guard let target else {
            scheduleHide()
            return
        }
        guard target != pendingTarget else { return }
        pendingWorkItem?.cancel()
        pendingTarget = target
        let workItem = DispatchWorkItem { [weak self] in self?.show(target: target, near: point) }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: workItem)
    }

    private func show(target: DockItemTarget, near dockPoint: CGPoint) {
        pendingTarget = nil
        guard isEnabled, resolver.target(at: dockPoint) == target,
              let windowsProvider else { return }
        let windows = windowsProvider(target)
        guard !windows.isEmpty else {
            hide()
            return
        }
        items = windows.map { window in
            Item(
                window: window,
                preview: previewProvider?(window.key),
                appIcon: NSRunningApplication(processIdentifier: window.appPID)?.icon
            )
        }
        let panel = self.panel ?? DockHoverPreviewPanel(
            onActivate: { [weak self] index in self?.activate(index: index) },
            onExit: { [weak self] in self?.hide() }
        )
        self.panel = panel
        shownTarget = target
        panel.show(
            items: items.map {
                DockHoverPreviewItem(title: $0.window.title, preview: $0.preview, appIcon: $0.appIcon)
            },
            near: NSScreenPoint.fromQuartz(dockPoint)
        )
        DiagnosticJournal.shared.log("dock_hover", "shown", fields: [
            "windows": items.count,
            "previews": items.filter { $0.preview != nil }.count
        ])
    }

    private func activate(index: Int) {
        guard items.indices.contains(index) else { return }
        let window = items[index].window
        hide()
        activationHandler?(window)
    }

    private func scheduleHide() {
        pendingWorkItem?.cancel()
        pendingTarget = nil
        let workItem = DispatchWorkItem { [weak self] in self?.hide() }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func hide() {
        hitTestWorkItem?.cancel()
        hitTestWorkItem = nil
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingTarget = nil
        shownTarget = nil
        items = []
        panel?.orderOut(nil)
    }
}

private enum NSScreenPoint {
    static func fromQuartz(_ point: CGPoint) -> NSPoint {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let quartzFrame = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard quartzFrame.contains(point) else { continue }
            return NSPoint(
                x: screen.frame.minX + point.x - quartzFrame.minX,
                y: screen.frame.maxY - (point.y - quartzFrame.minY)
            )
        }
        return NSPoint(x: point.x, y: point.y)
    }
}

private struct DockHoverPreviewItem {
    let title: String
    let preview: NSImage?
    let appIcon: NSImage?
}

private final class DockHoverPreviewPanel: NSPanel {
    private let previewView = DockHoverPreviewView()

    init(onActivate: @escaping (Int) -> Void, onExit: @escaping () -> Void) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let acrylic = NSVisualEffectView()
        acrylic.material = .hudWindow
        acrylic.blendingMode = .behindWindow
        acrylic.state = .active
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.onActivate = onActivate
        previewView.onExit = onExit
        acrylic.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: acrylic.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: acrylic.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: acrylic.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: acrylic.bottomAnchor),
        ])
        contentView = acrylic
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(items: [DockHoverPreviewItem], near point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let size = previewView.setItems(items, maximumSize: screen.visibleFrame.size)
        let distances = [
            ("left", abs(point.x - screen.frame.minX)),
            ("right", abs(screen.frame.maxX - point.x)),
            ("bottom", abs(point.y - screen.frame.minY)),
            ("top", abs(screen.frame.maxY - point.y)),
        ]
        let edge = distances.min(by: { $0.1 < $1.1 })?.0 ?? "bottom"
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y + 28)
        switch edge {
        case "top": origin.y = point.y - size.height - 28
        case "left": origin = NSPoint(x: point.x + 28, y: point.y - size.height / 2)
        case "right": origin = NSPoint(x: point.x - size.width - 28, y: point.y - size.height / 2)
        default: break
        }
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 10), screen.visibleFrame.maxX - size.width - 10)
        origin.y = min(max(origin.y, screen.visibleFrame.minY + 10), screen.visibleFrame.maxY - size.height - 10)
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }
}

private final class DockHoverPreviewView: NSView {
    private static let itemSize = NSSize(width: 220, height: 158)
    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 16
    private var items: [DockHoverPreviewItem] = []
    private var columns = 1
    private var trackingArea: NSTrackingArea?
    var onActivate: ((Int) -> Void)?
    var onExit: (() -> Void)?
    override var isFlipped: Bool { true }

    func setItems(_ items: [DockHoverPreviewItem], maximumSize: NSSize) -> NSSize {
        self.items = items
        columns = max(1, min(items.count, Int((maximumSize.width - 40 + Self.spacing) / (Self.itemSize.width + Self.spacing))))
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let width = Self.padding * 2 + CGFloat(columns) * Self.itemSize.width + CGFloat(max(0, columns - 1)) * Self.spacing
        let height = Self.padding * 2 + CGFloat(rows) * Self.itemSize.height + CGFloat(max(0, rows - 1)) * Self.spacing
        frame.size = NSSize(width: width, height: height)
        updateTrackingAreas()
        needsDisplay = true
        return frame.size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) { onExit?() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = itemIndex(at: point) else { return }
        onActivate?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (index, item) in items.enumerated() {
            let rect = itemRect(at: index)
            NSColor(calibratedWhite: 0.11, alpha: 0.72).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor(calibratedWhite: 0.30, alpha: 0.80).setStroke()
            NSBezierPath(rect: rect).stroke()
            let imageRect = NSRect(x: rect.minX + 8, y: rect.minY + 8, width: rect.width - 16, height: 108)
            if let image = item.preview ?? item.appIcon {
                image.draw(in: aspectFitRect(for: image.size, inside: imageRect), from: .zero, operation: .sourceOver, fraction: 1)
            }
            item.appIcon?.draw(in: NSRect(x: rect.minX + 8, y: rect.maxY - 29, width: 20, height: 20))
            ((item.title.isEmpty ? "Window" : item.title) as NSString).draw(
                in: NSRect(x: rect.minX + 35, y: rect.maxY - 28, width: rect.width - 43, height: 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
            )
        }
    }

    private func itemRect(at index: Int) -> NSRect {
        let column = index % columns
        let row = index / columns
        return NSRect(
            x: Self.padding + CGFloat(column) * (Self.itemSize.width + Self.spacing),
            y: Self.padding + CGFloat(row) * (Self.itemSize.height + Self.spacing),
            width: Self.itemSize.width,
            height: Self.itemSize.height
        )
    }

    private func itemIndex(at point: NSPoint) -> Int? {
        items.indices.first { itemRect(at: $0).contains(point) }
    }

    private func aspectFitRect(for imageSize: NSSize, inside bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}
