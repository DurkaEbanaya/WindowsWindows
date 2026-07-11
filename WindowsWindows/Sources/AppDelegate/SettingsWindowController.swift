import AppKit
import WebKit

@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private enum BridgeAction: String {
        case ready
        case openGitHub
        case toggleApplication
        case setLaunchAtLogin
        case setMinimizeOnRepeatClick
        case toggleTheme
        case closeWindow
        case zoomWindow
    }

    private let store: ConfigStore
    private let onWorkspaceChanged: @MainActor (WorkspaceConfig) -> Void
    private var window: NSWindow?
    private var webView: WKWebView?
    private var bridge: SettingsScriptBridge?
    private var preZoomFrame: NSRect?

    public init(store: ConfigStore, onWorkspaceChanged: @escaping @MainActor (WorkspaceConfig) -> Void) {
        self.store = store
        self.onWorkspaceChanged = onWorkspaceChanged
    }

    public func show() {
        if window == nil { buildWindow() }
        pushState()
        activateForInteraction()
        DispatchQueue.main.async { [weak self] in
            self?.activateForInteraction()
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        _ = NSApp.setActivationPolicy(.prohibited)
        return false
    }

    private func activateForInteraction() {
        _ = NSApp.setActivationPolicy(.accessory)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKey()
        window?.makeFirstResponder(webView)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushState()
        webView.evaluateJavaScript(Self.metricsScript) { result, error in
            DiagnosticJournal.shared.log("settings", "renderer_ready", fields: [
                "metrics": String(describing: result),
                "error": error?.localizedDescription ?? "none"
            ])
        }
    }

    fileprivate func receive(message: WKScriptMessage) async -> (Any?, String?) {
        guard let payload = message.body as? [String: Any],
              let rawAction = payload["action"] as? String,
              let action = BridgeAction(rawValue: rawAction) else {
            return (nil, "Invalid settings action")
        }

        switch action {
        case .ready:
            return stateReply()
        case .openGitHub:
            NSWorkspace.shared.open(URL(string: "https://github.com/DurkaEbanaya/WindowsWindows")!)
            return (["ok": true], nil)
        case .toggleApplication:
            guard let bundleIdentifier = payload["bundleIdentifier"] as? String,
                  Policy.isUserConfigurable(bundleIdentifier: bundleIdentifier) else {
                return (nil, "Invalid bundle identifier")
            }
            return mutateWorkspace { workspace in
                try workspace.updateActiveShelfConfig { config in
                    config.scopeMode = .allExceptListed
                    if let index = config.bundleIdentifiers.firstIndex(of: bundleIdentifier) {
                        config.bundleIdentifiers.remove(at: index)
                    } else {
                        config.bundleIdentifiers.append(bundleIdentifier)
                    }
                }
            }
        case .setLaunchAtLogin:
            guard let enabled = payload["enabled"] as? Bool else { return (nil, "Missing enabled") }
            return mutateWorkspace { $0.loginItem.isEnabled = enabled }
        case .setMinimizeOnRepeatClick:
            guard let enabled = payload["enabled"] as? Bool else { return (nil, "Missing enabled") }
            return mutateWorkspace { $0.behavior.minimizeOnRepeatClick = enabled }
        case .toggleTheme:
            return mutateWorkspace { workspace in
                workspace.appearance.theme = effectiveDarkTheme(workspace.appearance.theme) ? .light : .dark
            }
        case .closeWindow:
            window?.orderOut(nil)
            return (["ok": true], nil)
        case .zoomWindow:
            toggleZoom()
            return (["ok": true], nil)
        }
    }

    private func buildWindow() {
        guard let resourceURL = Bundle.main.url(forResource: "settings", withExtension: "html") else {
            fatalError("Settings renderer is missing from the application bundle")
        }

        let contentController = WKUserContentController()
        let bridge = SettingsScriptBridge(owner: self)
        contentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "nativeSettings")
        contentController.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false

        let window = InteractiveSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = NSSize(width: 460, height: 460)
        window.delegate = self
        window.center()

        let root = SettingsFrameView()
        root.translatesAutoresizingMaskIntoConstraints = false
        let chrome = SettingsChromeView(window: window)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)
        root.addSubview(chrome)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: root.topAnchor),
            chrome.heightAnchor.constraint(equalToConstant: 38),
        ])
        window.contentView = root

        self.bridge = bridge
        self.webView = webView
        self.window = window
        webView.loadFileURL(resourceURL, allowingReadAccessTo: resourceURL.deletingLastPathComponent())
    }

    private func pushState() {
        guard let webView, let state = stateReply().0,
              JSONSerialization.isValidJSONObject(state),
              let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.WindowsWindowsNative?.render(\(json))") { _, error in
            if let error {
                DiagnosticJournal.shared.log("settings", "render_failed", fields: ["error": error.localizedDescription])
            }
        }
    }

    private func stateReply() -> (Any?, String?) {
        do {
            let workspace = try store.loadWorkspace()
            let configured = workspace.activeProfile?.shelfConfig.bundleIdentifiers ?? []
            let applications: [[String: Any]] = ApplicationCatalog.load(configuredIDs: configured).map { row in
                [
                    "bundleIdentifier": row.bundleIdentifier,
                    "name": row.name,
                    "subtitle": row.isRunning ? "Работает" : row.bundleIdentifier,
                    "selected": configured.contains(row.bundleIdentifier),
                ]
            }
            return ([
                "applications": applications,
                "launchAtLogin": workspace.loginItem.isEnabled,
                "minimizeOnRepeatClick": workspace.behavior.minimizeOnRepeatClick,
                "theme": effectiveDarkTheme(workspace.appearance.theme) ? "dark" : "light",
            ], nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func mutateWorkspace(_ transform: (inout WorkspaceConfig) throws -> Void) -> (Any?, String?) {
        do {
            let workspace = try store.updateWorkspace(transform)
            onWorkspaceChanged(workspace)
            let reply = stateReply()
            pushState()
            return reply
        } catch {
            DiagnosticJournal.shared.log("settings", "workspace_update_failed", fields: ["error": error.localizedDescription])
            return (nil, error.localizedDescription)
        }
    }

    private func effectiveDarkTheme(_ preference: WorkspaceThemePreference) -> Bool {
        switch preference {
        case .dark: true
        case .light: false
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    fileprivate func toggleZoom() {
        guard let window else { return }
        if let preZoomFrame {
            window.setFrame(preZoomFrame, display: true, animate: true)
            self.preZoomFrame = nil
        } else {
            preZoomFrame = window.frame
            guard let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true, animate: true)
        }
    }

    private static let bridgeScript = #"""
    (() => {
      const native = window.webkit.messageHandlers.nativeSettings;
      const post = async (action, payload = {}) => native.postMessage({ action, ...payload });

      const icon = (name) => {
        const paths = {
          application: '<rect x="5" y="5" width="14" height="14"/><path d="M5 9h14"/>',
          launch: '<path d="M5 12h14M13 6l6 6-6 6"/>',
          window: '<rect x="5" y="5" width="14" height="10"/><path d="M8 19h8M9 9h6M12 15v4"/>',
          keyboard: '<rect x="4" y="7" width="16" height="10" rx="2"/><path d="M7 10h.01M10 10h.01M13 10h.01M16 10h.01M8 14h8"/>'
        };
        return `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">${paths[name]}</svg>`;
      };

      const reveal = (element) => {
        const edgeStrength = (distance) => {
          const value = Math.max(0, Math.min(1, 1 - distance / 56));
          return Number((value * value).toFixed(3));
        };
        element.addEventListener('pointermove', (event) => {
          const rect = element.getBoundingClientRect();
          const x = event.clientX - rect.left;
          const y = event.clientY - rect.top;
          element.style.setProperty('--reveal-x', `${x}px`);
          element.style.setProperty('--reveal-y', `${y}px`);
          element.style.setProperty('--edge-top', edgeStrength(y));
          element.style.setProperty('--edge-right', edgeStrength(rect.width - x));
          element.style.setProperty('--edge-bottom', edgeStrength(rect.height - y));
          element.style.setProperty('--edge-left', edgeStrength(x));
        });
        element.addEventListener('pointerdown', () => element.dataset.pressed = 'true');
        for (const event of ['pointerup', 'pointercancel', 'pointerleave']) {
          element.addEventListener(event, () => delete element.dataset.pressed);
        }
      };

      const row = ({ iconName, title, subtitle, control, selected = false }) => {
        const element = document.createElement('label');
        element.className = 'row';
        element.dataset.selected = String(selected);
        element.innerHTML = `<span class="app-icon" aria-hidden="true">${icon(iconName)}</span><span><span class="row-title"></span><span class="row-sub"></span></span>`;
        element.querySelector('.row-title').textContent = title;
        element.querySelector('.row-sub').textContent = subtitle;
        element.append(control);
        reveal(element);
        return element;
      };

      const check = (application) => {
        const input = document.createElement('input');
        input.className = 'check';
        input.type = 'checkbox';
        input.checked = application.selected;
        input.setAttribute('aria-label', `Исключить ${application.name}`);
        input.addEventListener('change', async () => {
          input.closest('.row').dataset.selected = String(input.checked);
          await post('toggleApplication', { bundleIdentifier: application.bundleIdentifier });
        });
        return input;
      };

      const toggle = (enabled, action, label) => {
        const input = document.createElement('input');
        input.className = 'switch';
        input.type = 'checkbox';
        input.checked = enabled;
        input.setAttribute('aria-label', label);
        input.addEventListener('change', () => post(action, { enabled: input.checked }));
        return input;
      };

      const render = (state) => {
        document.documentElement.dataset.theme = state.theme;
        const list = document.querySelector('[data-od-id="exceptions-list"]');
        list.classList.remove('scroll-list');
        list.replaceChildren(...state.applications.map(application => row({
          iconName: 'application', title: application.name, subtitle: application.subtitle,
          control: check(application), selected: application.selected
        })));

        const general = document.querySelector('[data-od-id="general-settings"]');
        const shortcut = document.createElement('input');
        shortcut.className = 'shortcut-control';
        shortcut.type = 'text';
        shortcut.value = '⌘⇧P';
        shortcut.setAttribute('aria-label', 'Назначить сочетание клавиш');
        general.replaceChildren(
          row({ iconName: 'launch', title: 'Запускать при включении', subtitle: 'Программа стартует вместе с системой.', control: toggle(state.launchAtLogin, 'setLaunchAtLogin', 'Запускать при включении') }),
          row({ iconName: 'window', title: 'Повторное нажатие на окно сворачивает его', subtitle: 'Клик по уже активной Dock-иконке прячет выбранное окно.', control: toggle(state.minimizeOnRepeatClick, 'setMinimizeOnRepeatClick', 'Повторное нажатие на окно сворачивает его') }),
          row({ iconName: 'keyboard', title: 'Сочетание клавиш', subtitle: 'Стандартное: ⌘⇧P. Можно назначить своё.', control: shortcut })
        );
        const themeToggle = document.querySelector('[data-od-id="theme-toggle"]');
        const isDark = state.theme === 'dark';
        themeToggle?.setAttribute('aria-pressed', String(isDark));
        themeToggle?.setAttribute('title', isDark ? 'Включить светлую тему' : 'Включить тёмную тему');
      };

      document.querySelector('[data-od-id="github-link"]')?.addEventListener('click', (event) => {
        event.preventDefault(); post('openGitHub');
      });
      const theme = document.querySelector('[data-od-id="theme-toggle"]');
      theme?.replaceWith(theme.cloneNode(true));
      document.querySelector('[data-od-id="theme-toggle"]')?.addEventListener('click', () => post('toggleTheme'));
      const traffic = document.querySelectorAll('.traffic span');
      traffic[0]?.addEventListener('click', () => post('closeWindow'));
      traffic[2]?.addEventListener('click', () => post('zoomWindow'));
      document.querySelector('.traffic')?.setAttribute('aria-hidden', 'false');
      document.querySelector('.traffic')?.style.setProperty('visibility', 'hidden');
      window.WindowsWindowsNative = { render };
      post('ready').then(render);
    })();
    """#

    private static let metricsScript = #"""
    (() => {
      const titlebar = document.querySelector('.titlebar');
      const content = document.querySelector('.content');
      const row = document.querySelector('.row');
      const list = document.querySelector('.scroll-list');
      const style = getComputedStyle(content);
      return JSON.stringify({
        width: innerWidth,
        height: innerHeight,
        titlebarHeight: titlebar?.getBoundingClientRect().height,
        contentPaddingTop: style.paddingTop,
        contentPaddingLeft: style.paddingLeft,
        rowHeight: row?.getBoundingClientRect().height,
        listHeight: list?.getBoundingClientRect().height
      });
    })()
    """#
}

@MainActor
private final class InteractiveSettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class SettingsFrameView: NSView {
    private enum ResizeZone { case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }
    private let resizeThickness: CGFloat = 8
    private var activeZone: ResizeZone?
    private var startMouse: NSPoint?
    private var startFrame: NSRect?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        setCursor(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        setCursor(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        zone(at: point) == nil ? super.hitTest(point) : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let t = resizeThickness
        let b = bounds
        addCursorRect(NSRect(x: 0, y: t, width: t, height: b.height - 2 * t), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.width - t, y: t, width: t, height: b.height - 2 * t), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: t, y: 0, width: b.width - 2 * t, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: t, y: b.height - t, width: b.width - 2 * t, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: 0, width: t, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: b.width - t, y: 0, width: t, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: b.height - t, width: t, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: b.width - t, y: b.height - t, width: t, height: t), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        activeZone = zone(at: convert(event.locationInWindow, from: nil))
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let zone = activeZone, let startMouse, let startFrame, let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        var frame = startFrame
        switch zone {
        case .left, .topLeft, .bottomLeft:
            frame.origin.x += dx
            frame.size.width -= dx
        default: break
        }
        switch zone {
        case .right, .topRight, .bottomRight: frame.size.width += dx
        default: break
        }
        switch zone {
        case .bottom, .bottomLeft, .bottomRight:
            frame.origin.y += dy
            frame.size.height -= dy
        default: break
        }
        switch zone {
        case .top, .topLeft, .topRight: frame.size.height += dy
        default: break
        }
        let minSize = window.minSize
        if frame.width < minSize.width {
            if zone == .left || zone == .topLeft || zone == .bottomLeft { frame.origin.x = startFrame.maxX - minSize.width }
            frame.size.width = minSize.width
        }
        if frame.height < minSize.height {
            if zone == .bottom || zone == .bottomLeft || zone == .bottomRight { frame.origin.y = startFrame.maxY - minSize.height }
            frame.size.height = minSize.height
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeZone = nil
        startMouse = nil
        startFrame = nil
    }

    private func zone(at point: NSPoint) -> ResizeZone? {
        let t = resizeThickness
        let left = point.x <= t
        let right = point.x >= bounds.width - t
        let bottom = point.y <= t
        let top = point.y >= bounds.height - t
        if top && left { return .topLeft }
        if top && right { return .topRight }
        if bottom && left { return .bottomLeft }
        if bottom && right { return .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        if bottom { return .bottom }
        return nil
    }

    private func setCursor(for point: NSPoint) {
        switch zone(at: point) {
        case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight:
            NSCursor.resizeLeftRight.set()
        case .top, .bottom:
            NSCursor.resizeUpDown.set()
        case nil:
            NSCursor.arrow.set()
        }
    }
}

@MainActor
private final class SettingsChromeView: NSView {
    private let hostWindow: NSWindow
    private let titlebarHeight: CGFloat = 38
    private var draggingStartMouse: NSPoint?
    private var draggingStartOrigin: NSPoint?

    override var isFlipped: Bool { true }

    init(window: NSWindow) {
        self.hostWindow = window
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor

        let title = NSTextField(labelWithString: "WindowsWindows")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let close = SettingsFrameButton(title: "×", action: #selector(closeWindow), target: self)
        let zoom = SettingsFrameButton(title: "□", action: #selector(zoomWindow), target: self)
        let buttons = [close, zoom]
        for (index, button) in buttons.enumerated() {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor),
                button.widthAnchor.constraint(equalToConstant: 46),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(index) * 46),
            ])
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: titlebarHeight),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        draggingStartMouse = NSEvent.mouseLocation
        draggingStartOrigin = hostWindow.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = draggingStartMouse, let startOrigin = draggingStartOrigin else { return }
        let current = NSEvent.mouseLocation
        hostWindow.setFrameOrigin(NSPoint(x: startOrigin.x + current.x - startMouse.x, y: startOrigin.y + current.y - startMouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        draggingStartMouse = nil
        draggingStartOrigin = nil
    }

    @objc private func closeWindow() { hostWindow.orderOut(nil) }
    @objc private func zoomWindow() {
        if let delegate = hostWindow.delegate as? SettingsWindowController {
            delegate.toggleZoom()
        }
    }
}

@MainActor
private final class SettingsFrameButton: NSButton {
    init(title: String, action: Selector, target: AnyObject) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        isEnabled = true
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 15, weight: .regular)
        alignment = .center
        contentTintColor = .labelColor
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedControlColor.withAlphaComponent(0.18).setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
    }
}

@MainActor
private final class SettingsScriptBridge: NSObject, WKScriptMessageHandlerWithReply {
    private weak var owner: SettingsWindowController?

    init(owner: SettingsWindowController) {
        self.owner = owner
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let owner else { return (nil, "Settings window no longer exists") }
        return await owner.receive(message: message)
    }
}
