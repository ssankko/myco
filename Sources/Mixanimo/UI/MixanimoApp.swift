import AppKit
import SwiftUI

@main
@MainActor
struct MixanimoApp: App {
    @State private var model: AppModel
    @State private var actions: Actions
    @State private var engine: Engine

    init() {
        // Mixanimo lives in the menu bar, so it takes no Dock tile and no main menu.
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel()
        let actions = Actions()
        let engine = Engine(model: model)
        actions.install = { try? await engine.installDriver() }
        actions.uninstall = { try? await engine.uninstallDriver() }
        engine.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { engine.stop() } }
        _model = State(initialValue: model)
        _actions = State(initialValue: actions)
        _engine = State(initialValue: engine)
        StatusItem.install(Popover(model: model, actions: actions))
    }

    var body: some Scene {
        // One equaliser window per output. `Window` gained a value-carrying form after
        // macOS 14, so the group stands in for it. With no default value the group opens
        // nothing until a row asks for a window.
        WindowGroup("Equaliser", id: "eq", for: String.self) { $uid in
            if let uid {
                EQWindow(model: model, uid: uid)
                    // An accessory app opens windows behind whatever is in front otherwise.
                    .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
            }
        }
        .windowResizability(.contentSize)
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

    private init(content: some View) {
        super.init()
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        item.button?.image = MixanimoMark.statusImage
        item.button?.setAccessibilityLabel("Mixanimo")
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // An accessory app is not frontmost after a status item click, and the popover needs
        // an active app to take the key window and with it the keyboard shortcuts.
        NSApplication.shared.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
