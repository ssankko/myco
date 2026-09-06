import AppKit
import SwiftUI

/// The app's colour, spacing and number formatting, kept in one place so a row and the EQ window
/// read as the same instrument.
enum Theme {
    /// Lit signal. Every control that carries audio borrows this colour.
    static let signal = dynamic(light: (0.24, 0.31, 0.80), dark: (0.51, 0.57, 1.00))
    /// Something works but needs attention: underruns, an old driver.
    static let caution = dynamic(light: (0.72, 0.47, 0.06), dark: (0.95, 0.70, 0.25))
    /// Nothing is flowing: no driver, a dead device.
    static let stopped = dynamic(light: (0.76, 0.25, 0.24), dark: (1.00, 0.45, 0.42))

    /// Hairline the rails and dividers share, so an idle row still shows its lane.
    static let track = Color.primary.opacity(0.11)

    /// Behind a device that carries audio, and the same fill lifted under the pointer.
    static let cardFill = signal.opacity(0.08)
    static let cardFillHover = signal.opacity(0.15)
    /// Under the pointer on a device that is off.
    static let rowFillHover = Color.primary.opacity(0.06)
    /// Around a small button, so it reads as one before the pointer reaches it.
    static let border = Color.primary.opacity(0.22)

    static let rowGap: CGFloat = 10
    static let sectionGap: CGFloat = 14
    static let cardRadius: CGFloat = 8
    static let cardPadding: CGFloat = 8
    static let glyphHeight: CGFloat = 19
    static let glyphRadius: CGFloat = 5
    static let popoverWidth: CGFloat = 380

    private static func dynamic(
        light: (Double, Double, Double), dark: (Double, Double, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// Readouts the eye can scan down a column: fixed sign, fixed decimals.
enum Readout {
    static func decibels(_ value: Double) -> String { String(format: "%+.1f", value) }
    static func decibels(_ value: Float) -> String { decibels(Double(value)) }
    static func milliseconds(_ value: Double) -> String { String(format: "%.1f", value) }
    static func percent(_ scalar: Float) -> String { "\(Int((scalar * 100).rounded()))" }

    static func hertz(_ value: Double) -> String {
        value >= 1000
            ? String(format: "%.2f kHz", value / 1000)
            : String(format: "%.0f Hz", value)
    }

    static func octaves(_ value: Double) -> String { String(format: "%.2f oct", value) }

    /// Short enough for a band chip: no unit, thousands as `k`, no trailing zero.
    static func compactHertz(_ value: Double) -> String {
        guard value >= 1000 else { return String(format: "%.0f", value) }
        let thousands = value / 1000
        return thousands == thousands.rounded()
            ? String(format: "%.0fk", thousands)
            : String(format: "%.1fk", thousands)
    }
}
