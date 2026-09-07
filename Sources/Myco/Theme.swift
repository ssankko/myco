import AppKit
import SwiftUI

/// The app's colour, spacing and number formatting, kept in one place so a row and the EQ window
/// read as the same instrument.
enum Theme {
    /// The brand: pale mint on deep forest, as on the app icon.
    static let brandMint = Color(red: 0xC5 / 255, green: 0xF4 / 255, blue: 0xD4 / 255)
    static let brandForest = Color(red: 0x17 / 255, green: 0x3B / 255, blue: 0x30 / 255)

    /// Lit signal. Every control that carries audio borrows this colour: the accent chosen in
    /// System Settings, or the brand green when that setting is Multicolor.
    static var signal: Color { Accent.shared.system ?? brandSignal }
    /// Text and glyphs on top of `signal`.
    static let onSignal = Color.white
    /// The forest hue at the saturation of the system accents, a step lighter on a dark
    /// background so it still stands off it.
    private static let brandSignal = dynamic(light: (0.16, 0.47, 0.37), dark: (0.20, 0.60, 0.48))
    /// Something works but needs attention: underruns, an old driver.
    static let caution = dynamic(light: (0.72, 0.47, 0.06), dark: (0.95, 0.70, 0.25))
    /// Nothing is flowing: no driver, a dead device.
    static let stopped = dynamic(light: (0.76, 0.25, 0.24), dark: (1.00, 0.45, 0.42))
    /// A control that takes something away and does not put it back.
    static let danger = stopped

    /// Hairline for dividers.
    static let track = Color.primary.opacity(0.11)

    /// Behind a device that carries audio, and the same fill lifted under the pointer.
    static var cardFill: Color { signal.opacity(0.08) }
    static var cardFillHover: Color { signal.opacity(0.15) }
    /// Under the pointer on a device that is off.
    static let rowFillHover = Color.primary.opacity(0.06)
    /// Around a small button, so it reads as one before the pointer reaches it, and once it has.
    static let border = Color.primary.opacity(0.22)
    static let borderHover = Color.primary.opacity(0.4)
    /// A lit button under the pointer.
    static var signalHover: Color { signal.opacity(0.8) }

    static let sectionGap: CGFloat = 14
    static let cardRadius: CGFloat = 8
    static let cardPadding: CGFloat = 8
    static let glyphHeight: CGFloat = 19
    static let glyphRadius: CGFloat = 5
    static let popoverWidth: CGFloat = 380

    fileprivate static func dynamic(
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

/// The accent picked in System Settings. A chosen colour is used as it is; "Multicolor" is
/// nil and stands for the app's own colour.
@Observable
final class Accent: @unchecked Sendable {
    static let shared = Accent()

    private(set) var system: Color?

    private init() {
        refresh()
        // AppKit posts this once it has re-read the accent, so `controlAccentColor` is fresh.
        NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        // The key is absent while the setting is Multicolor.
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        guard global?["AppleAccentColor"] != nil else { return system = nil }
        // Resolved to components per appearance: wrapped as an NSColor, SwiftUI would swap the
        // accent for the app's own.
        func resolved(_ name: NSAppearance.Name) -> (Double, Double, Double) {
            var c = NSColor.black
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                c = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
            }
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        system = Theme.dynamic(light: resolved(.aqua), dark: resolved(.darkAqua))
    }
}
