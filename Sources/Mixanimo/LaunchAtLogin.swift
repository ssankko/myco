import Foundation
import MixanimoEngine
import Observation
import ServiceManagement
import os

/// Keeps the login items in step with `settings.launchAtLogin`.
@MainActor
enum LaunchAtLogin {
    private static let log = Logger(subsystem: AppModel.appBundleID, category: "launch")
    /// The value last pushed to the service; nil until the first one.
    private static var applied: Bool?

    /// Applies the setting now and again after every change to it.
    static func observe(_ model: AppModel) {
        withObservationTracking {
            apply(model.settings.launchAtLogin)
        } onChange: {
            // The change lands after this callback, so the new value is read from a fresh turn.
            Task { @MainActor in observe(model) }
        }
    }

    private static func apply(_ wanted: Bool) {
        // Only the shipped app may register itself; a test host must not end up in the login items.
        guard Bundle.main.bundleIdentifier == AppModel.appBundleID else { return }
        guard wanted != applied else { return }
        applied = wanted
        // The service refuses an unregister it never registered, so a setting that already matches
        // the login items is left alone rather than pushed again.
        guard wanted != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("launch at login \(wanted): \(String(describing: error), privacy: .public)")
        }
    }
}
