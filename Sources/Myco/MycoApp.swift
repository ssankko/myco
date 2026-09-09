import AppKit
import MycoEngine
import SwiftUI

@main
@MainActor
struct MycoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel
    @State private var actions: Actions
    @State private var engine: Engine
    @State private var updater: Updater

    init() {
        // Myco lives in the menu bar, so it takes no Dock tile and no main menu.
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel()
        let actions = Actions()
        let engine = Engine(model: model)
        LaunchAtLogin.observe(model)
        Hotkeys.shared.watch(model)
        let updater = Updater()
        updater.start()
        actions.install = { try? await engine.installDriver() }
        actions.uninstall = { try? await engine.uninstallDriver() }
        Task { await engine.start() }
        AppDelegate.stop = { await engine.stop() }
        _model = State(initialValue: model)
        _actions = State(initialValue: actions)
        _engine = State(initialValue: engine)
        _updater = State(initialValue: updater)
        let panels = Panels()
        StatusItem.install(
            Popover(model: model, actions: actions, updater: updater, panels: panels),
            model: model, actions: actions, panels: panels)
    }

    var body: some Scene {
        // A scene group would open a window of its own at launch, which then pins the app to the
        // space it launched in; the menu bar window is a plain AppKit window.
        SwiftUI.Settings { EmptyView() }
    }
}

/// Holds the quit until the engine has faded out and put the default devices back.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var stop: (() async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let stop = AppDelegate.stop else { return .terminateNow }
        AppDelegate.stop = nil
        Task {
            await stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The menu bar item, the window a click opens and the menu a right click opens. The window is
/// drawn like a popover but hangs from a fixed right edge, so a panel that opens beside the main
/// column grows to the left and the column stays where it was.
@MainActor
final class StatusItem: NSObject {
    /// The status bar keeps no strong reference, so the app's one item lives here.
    private static var live: StatusItem?

    static func install(_ content: some View, model: AppModel, actions: Actions, panels: Panels) {
        live = StatusItem(content: content, model: model, actions: actions, panels: panels)
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let window = PopoverWindow()
    private let model: AppModel
    private let actions: Actions
    private let panels: Panels
    /// Watches for clicks in other apps while the window is open.
    private var outsideClicks: Any?
    /// Watches for Escape and Cmd-Q while the window is open.
    private var localEvents: Any?
    private var becameActive: (any NSObjectProtocol)?

    private init(content: some View, model: AppModel, actions: Actions, panels: Panels) {
        self.model = model
        self.actions = actions
        self.panels = panels
        super.init()
        window.host(
            content.onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                self?.fit(size)
            })
        item.button?.image = MycoMark.glyph
        item.button?.image?.size = NSSize(width: 18, height: 18)
        item.button?.setAccessibilityLabel("Myco")
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func toggle(_ sender: Any?) {
        if window.isVisible {
            close()
            return
        }
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        // An accessory app is not frontmost after a status item click, and cooperative activation
        // lands a moment later. The frontmost app is asked to yield, and the window is made key as
        // soon as the app is active, so its controls draw active and take Cmd-Q.
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            _ = NSRunningApplication.current.activate(from: front, options: [])
        } else {
            NSApplication.shared.activate()
        }
        fit(window.idealSize)
        window.makeKeyAndOrderFront(nil)
        becameActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.window.makeKey() }
        }
        // A click in another app closes the window. Escape closes the open panel first, then the
        // window.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let quit = event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q"
            if quit {
                MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                return nil
            }
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.panels.open != nil { self.panels.open = nil } else { self.close() }
            }
            return nil
        }
    }

    /// The window hangs under the status item with the main column centred on it, as far as the
    /// screen allows; a wider content keeps that right edge and takes the room to the left.
    private func fit(_ size: CGSize) {
        guard let button = item.button, let anchor = button.window else { return }
        let screen = anchor.screen?.visibleFrame ?? anchor.frame
        let itemCenter = anchor.convertToScreen(button.convert(button.bounds, to: nil)).midX
        let right = min(itemCenter + Theme.popoverWidth / 2, screen.maxX - 8)
        let top = min(anchor.frame.minY - 5, screen.maxY)
        let width = min(size.width, screen.width - 16)
        let height = min(size.height, screen.height - 8)
        window.setFrame(NSRect(x: right - width, y: top - height, width: width, height: height), display: true)
    }

    private func close() {
        window.orderOut(nil)
        panels.open = nil
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        if let localEvents { NSEvent.removeMonitor(localEvents) }
        localEvents = nil
        if let becameActive { NotificationCenter.default.removeObserver(becameActive) }
        becameActive = nil
    }

    /// The item's menu is set only for the duration of the click, so a left click keeps opening
    /// the window.
    private func showMenu() {
        let menu = NSMenu()
        let remove = NSMenuItem(title: "Remove driver", action: #selector(removeDriver), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = model.driver.isReady && actions.uninstall != nil && !actions.isWorking
        menu.addItem(remove)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Myco", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func removeDriver() { actions.run(actions.uninstall) }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

/// A borderless window with the look of a popover: the popover material, rounded corners and a
/// shadow. It follows the user across spaces and sits over a full-screen app.
private final class PopoverWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Theme.popoverWidth, height: 200),
            styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isMovable = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // Above every app window, under system alerts such as a permission prompt.
        level = .floating
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 10
        material.layer?.masksToBounds = true
        contentView = material
    }

    private var host: NSView?

    override var canBecomeKey: Bool { true }

    /// The size the content asks for. The window is sized from outside, so the content view's
    /// own size never drives the frame: a frame set by Auto Layout would keep the bottom left
    /// corner in place, and the window hangs from its top right.
    var idealSize: CGSize {
        let size = host?.intrinsicContentSize ?? .zero
        return size.width > 0 ? size : frame.size
    }

    func host(_ content: some View) {
        guard let contentView else { return }
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            host.setContentHuggingPriority(.defaultLow, for: axis)
            host.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        contentView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        self.host = host
    }
}
