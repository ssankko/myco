import Observation

/// The work the popover asks for but does not know how to do. The engine fills the closures in;
/// until it does, the buttons that need them stay disabled.
@MainActor
@Observable
final class Actions {
    var install: (() async -> Void)?
    var uninstall: (() async -> Void)?

    /// True while a driver action runs, so the popover can show progress and refuse a second click.
    private(set) var isWorking = false

    func run(_ action: (() async -> Void)?) {
        guard let action, !isWorking else { return }
        isWorking = true
        Task {
            await action()
            isWorking = false
        }
    }
}
