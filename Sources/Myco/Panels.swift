import SwiftUI

/// A panel that opens beside the main column of the menu bar window.
enum Panel: Equatable {
    case eq(String)
    case profiles

    /// The least a panel is given; the shortest column still leaves room for the equaliser.
    static let minHeight: CGFloat = 440
}

/// Which panel is open, shared by the rows that open one and the window that closes it.
@MainActor
@Observable
final class Panels {
    var open: Panel?

    /// Opens the panel, or closes it when it is the one already open.
    func toggle(_ panel: Panel) {
        open = open == panel ? nil : panel
    }
}
