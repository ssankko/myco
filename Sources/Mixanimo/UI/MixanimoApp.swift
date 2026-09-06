import AppKit
import SwiftUI

@main
@MainActor
struct MixanimoApp: App {
    @State private var model = AppModel()
    @State private var actions = Actions()

    init() {
        // Mixanimo lives in the menu bar, so it takes no Dock tile and no main menu.
        NSApplication.shared.setActivationPolicy(.accessory)
        // Engine(model:) is attached here
    }

    var body: some Scene {
        MenuBarExtra {
            Popover(model: model, actions: actions)
        } label: {
            MixanimoMark(isLive: model.driver.isReady)
                .frame(width: 15, height: 13)
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
