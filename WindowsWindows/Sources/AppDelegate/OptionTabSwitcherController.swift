import Cocoa
import CoreGraphics

public struct WindowSwitchSelection: Equatable, Sendable {
    public let keys: [WindowKey]
    public private(set) var selectedIndex: Int

    public init(keys: [WindowKey], focusedKey: WindowKey?, reverse: Bool) {
        self.keys = keys
        guard !keys.isEmpty else {
            selectedIndex = 0
            return
        }
        let focusedIndex = focusedKey.flatMap { keys.firstIndex(of: $0) }
        if reverse {
            selectedIndex = focusedIndex.map { ($0 - 1 + keys.count) % keys.count } ?? (keys.count - 1)
        } else {
            selectedIndex = focusedIndex.map { ($0 + 1) % keys.count } ?? 0
        }
    }

    public mutating func advance(reverse: Bool) {
        guard !keys.isEmpty else { return }
        selectedIndex = reverse
            ? (selectedIndex - 1 + keys.count) % keys.count
            : (selectedIndex + 1) % keys.count
    }

    public mutating func select(index: Int) {
        guard keys.indices.contains(index) else { return }
        selectedIndex = index
    }

    public var selectedKey: WindowKey? {
        keys.indices.contains(selectedIndex) ? keys[selectedIndex] : nil
    }
}

@MainActor
public final class OptionTabSwitcherController {
    private struct Item {
        let window: ObservedWindow
        let preview: NSImage?
        let appIcon: NSImage?
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var panel: WindowSwitcherPanel?
    private var items: [Item] = []
    private var selection: WindowSwitchSelection?
    private var recentKeys: [WindowKey] = []
    private var windowsProvider: (() -> [ObservedWindow])?
    private var focusedKeyProvider: (() -> WindowKey?)?
    private var previewProvider: ((WindowKey) -> NSImage?)?
    private var activationHandler: ((ObservedWindow) -> Void)?

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
        windows: @escaping () -> [ObservedWindow],
        focusedKey: @escaping () -> WindowKey?,
        preview: @escaping (WindowKey) -> NSImage?,
        activate: @escaping (ObservedWindow) -> Void
    ) {
        stop()
        windowsProvider = windows
        focusedKeyProvider = focusedKey
        previewProvider = preview
        activationHandler = activate

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<OptionTabSwitcherController>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    controller.handle(type: type, event: event)
                        ? nil
                        : Unmanaged.passUnretained(event)
                }
            },
            userInfo: context
        ) else {
            DiagnosticJournal.shared.log("option_tab", "event_tap_registration_failed")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DiagnosticJournal.shared.log("option_tab", "event_tap_registered")
    }

    public func stop() {
        cancel()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        windowsProvider = nil
        focusedKeyProvider = nil
        previewProvider = nil
        activationHandler = nil
    }

    public func noteFocusedWindow(_ key: WindowKey) {
        recentKeys.removeAll { $0 == key }
        recentKeys.insert(key, at: 0)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }

        if type == .flagsChanged {
            if panel != nil && !event.flags.contains(.maskAlternate) {
                commit()
            }
            return false
        }

        guard type == .keyDown else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 48,
           event.flags.contains(.maskAlternate),
           !event.flags.contains(.maskCommand),
           !event.flags.contains(.maskControl) {
            return cycle(reverse: event.flags.contains(.maskShift))
        }
        if keyCode == 53 && panel != nil {
            cancel()
            return true
        }
        return false
    }

    private func cycle(reverse: Bool) -> Bool {
        if panel != nil {
            selection?.advance(reverse: reverse)
            refreshSelection()
            return true
        }

        guard let windowsProvider else { return false }
        let windows = windowsProvider()
        guard !windows.isEmpty else { return false }
        let byKey = Dictionary(uniqueKeysWithValues: windows.map { ($0.key, $0) })
        let focusedKey = focusedKeyProvider?()
        var orderedKeys: [WindowKey] = []
        if let focusedKey, byKey[focusedKey] != nil {
            orderedKeys.append(focusedKey)
        }
        orderedKeys.append(contentsOf: recentKeys.filter { byKey[$0] != nil && !orderedKeys.contains($0) })
        orderedKeys.append(contentsOf: windows.map(\.key).filter { !orderedKeys.contains($0) })

        items = orderedKeys.compactMap { key in
            guard let window = byKey[key] else { return nil }
            return Item(
                window: window,
                preview: previewProvider?(key),
                appIcon: NSRunningApplication(processIdentifier: window.appPID)?.icon
            )
        }
        selection = WindowSwitchSelection(keys: orderedKeys, focusedKey: focusedKey, reverse: reverse)
        let panel = WindowSwitcherPanel(
            onSelectionChange: { [weak self] index in
                self?.selection?.select(index: index)
            },
            onActivate: { [weak self] index in
                self?.selection?.select(index: index)
                self?.commit()
            }
        )
        self.panel = panel
        panel.show(
            items: items.map {
                WindowSwitcherItem(appName: $0.window.appName, title: $0.window.title, preview: $0.preview, appIcon: $0.appIcon)
            },
            selectedIndex: selection?.selectedIndex ?? 0
        )
        DiagnosticJournal.shared.log("option_tab", "shown", fields: [
            "windows": items.count,
            "previews": items.filter { $0.preview != nil }.count
        ])
        return true
    }

    private func refreshSelection() {
        guard let selectedIndex = selection?.selectedIndex else { return }
        panel?.selectedIndex = selectedIndex
    }

    private func commit() {
        let selectedKey = selection?.selectedKey
        let selectedWindow = items.first { $0.window.key == selectedKey }?.window
        hide()
        if let selectedWindow {
            noteFocusedWindow(selectedWindow.key)
            activationHandler?(selectedWindow)
            DiagnosticJournal.shared.log("option_tab", "activated", fields: [
                "key": selectedWindow.key.stringValue
            ])
        }
    }

    private func cancel() {
        guard panel != nil else { return }
        hide()
        DiagnosticJournal.shared.log("option_tab", "cancelled")
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
        items = []
        selection = nil
    }
}

private struct WindowSwitcherItem {
    let appName: String
    let title: String
    let preview: NSImage?
    let appIcon: NSImage?
}

private final class WindowSwitcherPanel: NSPanel {
    private let switcherView = WindowSwitcherView()

    var selectedIndex: Int {
        get { switcherView.selectedIndex }
        set { switcherView.selectedIndex = newValue }
    }

    init(onSelectionChange: @escaping (Int) -> Void, onActivate: @escaping (Int) -> Void) {
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
        switcherView.translatesAutoresizingMaskIntoConstraints = false
        switcherView.onSelectionChange = onSelectionChange
        switcherView.onActivate = onActivate
        acrylic.addSubview(switcherView)
        NSLayoutConstraint.activate([
            switcherView.leadingAnchor.constraint(equalTo: acrylic.leadingAnchor),
            switcherView.trailingAnchor.constraint(equalTo: acrylic.trailingAnchor),
            switcherView.topAnchor.constraint(equalTo: acrylic.topAnchor),
            switcherView.bottomAnchor.constraint(equalTo: acrylic.bottomAnchor),
        ])
        contentView = acrylic
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(items: [WindowSwitcherItem], selectedIndex: Int) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let size = switcherView.setItems(items, selectedIndex: selectedIndex, maximumSize: screen.visibleFrame.size)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }
}

private final class WindowSwitcherView: NSView {
    private static let itemSize = NSSize(width: 220, height: 158)
    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 20
    private var items: [WindowSwitcherItem] = []
    private var columns = 1
    private var trackingArea: NSTrackingArea?
    var onSelectionChange: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?

    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = itemIndex(at: convert(event.locationInWindow, from: nil)), index != selectedIndex else { return }
        selectedIndex = index
        onSelectionChange?(index)
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = itemIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        selectedIndex = index
        onSelectionChange?(index)
        onActivate?(index)
    }

    func setItems(_ items: [WindowSwitcherItem], selectedIndex: Int, maximumSize: NSSize) -> NSSize {
        self.items = items
        self.selectedIndex = selectedIndex
        let availableWidth = max(Self.itemSize.width, maximumSize.width - 80)
        columns = max(1, min(items.count, Int((availableWidth + Self.spacing) / (Self.itemSize.width + Self.spacing))))
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let width = Self.padding * 2 + CGFloat(columns) * Self.itemSize.width + CGFloat(max(0, columns - 1)) * Self.spacing
        let height = Self.padding * 2 + CGFloat(rows) * Self.itemSize.height + CGFloat(max(0, rows - 1)) * Self.spacing
        frame.size = NSSize(width: width, height: height)
        updateTrackingAreas()
        needsDisplay = true
        return frame.size
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (index, item) in items.enumerated() {
            draw(item: item, in: itemRect(at: index), selected: index == selectedIndex)
        }
    }

    private func draw(item: WindowSwitcherItem, in rect: NSRect, selected: Bool) {
        (selected ? NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 0.92) : NSColor(calibratedWhite: 0.18, alpha: 0.68)).setFill()
        NSBezierPath(rect: rect).fill()

        let inset: CGFloat = selected ? 4 : 1
        let contentRect = rect.insetBy(dx: inset, dy: inset)
        NSColor(calibratedWhite: 0.10, alpha: 0.70).setFill()
        NSBezierPath(rect: contentRect).fill()

        let imageRect = NSRect(x: contentRect.minX + 8, y: contentRect.minY + 8, width: contentRect.width - 16, height: 108)
        if let image = item.preview ?? item.appIcon {
            image.draw(in: aspectFitRect(for: image.size, inside: imageRect), from: .zero, operation: .sourceOver, fraction: 1)
        }

        let iconRect = NSRect(x: contentRect.minX + 8, y: contentRect.maxY - 29, width: 20, height: 20)
        item.appIcon?.draw(in: iconRect)
        let title = item.title.isEmpty ? item.appName : item.title
        (title as NSString).draw(
            in: NSRect(x: iconRect.maxX + 7, y: contentRect.maxY - 28, width: contentRect.width - 43, height: 20),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
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
