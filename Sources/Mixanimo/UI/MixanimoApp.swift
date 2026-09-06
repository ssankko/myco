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
    }

    var body: some Scene {
        MenuBarExtra {
            Popover(model: model, actions: actions)
        } label: {
            Image(nsImage: MixanimoMark.statusImage)
                .accessibilityLabel("Mixanimo")
        }
        .menuBarExtraStyle(.window)

        // One equaliser window per output. `Window` gained a value-carrying form after
        // macOS 14, so the group stands in for it.
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
