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
        StatusItem.install(Popover(model: model, actions: actions, updater: updater))
    }

    var body: some Scene {
        // A scene group would open a window of its own at launch, which then pins the app to the
        // space it launched in; the equaliser windows are plain windows opened by `EQWindows`.
        SwiftUI.Settings { EmptyView() }
    }
}

/// One equaliser window per output. A window is kept once made, so closing and reopening it
/// keeps its state, and it follows the user to whichever space they are on.
@MainActor
enum EQWindows {
    private static var windows: [String: NSWindow] = [:]

    static func show(model: AppModel, uid: String) {
        let window = windows[uid] ?? make(model: model, uid: uid)
        windows[uid] = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    private static func make(model: AppModel, uid: String) -> NSWindow {
        let host = NSHostingController(rootView: EQWindow(model: model, uid: uid))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.title = (try? AudioDevice.find(uid: uid))??.name.nilIfEmpty ?? "Equaliser"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // Ordering the window front brings it to the current space rather than switching to
        // the one it was last on, and a full-screen app does not hide it.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        return window
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

/// The menu bar item and the popover it opens. `MenuBarExtra` measures its window once and keeps
/// that size, which clips every control that appears later; an `NSPopover` over an
/// `NSHostingController` follows the content size instead.
@MainActor
final class StatusItem: NSObject {
    /// The status bar keeps no strong reference, so the app's one item lives here.
    private static var live: StatusItem?

    static func install(_ content: some View) { live = StatusItem(content: content) }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    /// Watches for clicks in other apps while the popover is open.
    private var outsideClicks: Any?
    /// Watches for clicks in this app's other windows, and for Escape, while the popover is open.
    private var localEvents: Any?
    private var becameActive: (any NSObjectProtocol)?

    private init(content: some View) {
        super.init()
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // A transient popover closes when the app loses focus, which a space switch causes; the
        // closing is done here instead, on any click outside the popover or on Escape.
        popover.behavior = .applicationDefined
        // Every content size change is animated, and the animation re-anchors the window while it
        // resizes, so a row that opens makes the whole popover slide.
        popover.animates = false
        popover.delegate = self
        item.button?.image = MycoMark.glyph
        item.button?.image?.size = NSSize(width: 18, height: 18)
        item.button?.setAccessibilityLabel("Myco")
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // An accessory app is not frontmost after a status item click, and cooperative activation
        // lands a moment later. The frontmost app is asked to yield, and the popover window is
        // made key as soon as the app is active, so its controls draw active and take Cmd-Q.
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            _ = NSRunningApplication.current.activate(from: front, options: [])
        } else {
            NSApplication.shared.activate()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            // The popover stays with the user across a space switch, over a full-screen app too.
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.makeKey()
        }
        becameActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.contentViewController?.view.window?.makeKey() }
        }
        // The global monitor sees the clicks that land in other apps; the local one sees this
        // app's own, and lets the ones inside the popover through.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            let escape = event.type == .keyDown && event.keyCode == 53
            let closes = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let inside = event.window == self.popover.contentViewController?.view.window
                return escape || (event.type != .keyDown && !inside)
            }
            guard closes else { return event }
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
            return escape ? nil : event
        }
    }
}

extension StatusItem: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        if let localEvents { NSEvent.removeMonitor(localEvents) }
        localEvents = nil
        if let becameActive { NotificationCenter.default.removeObserver(becameActive) }
        becameActive = nil
    }
}
