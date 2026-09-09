import MycoDSP
import MycoEngine
import SwiftUI

/// The AutoEq presets shipped in `Contents/Resources/autoeq.json`, decoded once off the main
/// thread. Empty until the decode lands.
@MainActor
@Observable
final class PresetLibrary {
    static let shared = PresetLibrary()

    struct Entry {
        let preset: EQPreset
        /// Lowercased name and measurer, what the search field matches against.
        let key: String
    }

    private(set) var autoEq: [Entry] = []

    private init() {
        Task.detached(priority: .utility) {
            guard let url = Bundle.main.url(forResource: "autoeq", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let presets = try? EQPreset.autoEq(from: data) else { return }
            let entries = presets.map { Entry(preset: $0, key: "\($0.name) \($0.source)".lowercased()) }
            await MainActor.run { self.autoEq = entries }
        }
    }
}

extension AppModel {
    /// A band changed by hand: the curve no longer matches any preset by name. A write that
    /// leaves the bands as they are, such as a field committing the value it shows, keeps it.
    func editEQ(_ uid: String, _ change: (inout [BandSettings]) -> Void) {
        updateOutput(uid) {
            let before = $0.eq
            change(&$0.eq)
            if $0.eq != before { $0.presetName = nil }
        }
    }

    /// The preamp lands on the output's volume trim, so the boosted bands do not clip. The bands
    /// are rounded to what the inspector fields show, so a field cannot change them by itself.
    func apply(_ preset: EQPreset, to uid: String) {
        updateOutput(uid) {
            $0.eq = preset.bands.map { band in
                var band = band
                band.frequency = (band.frequency * 10).rounded() / 10
                band.gainDB = (band.gainDB * 10).rounded() / 10
                band.bandwidth = (band.bandwidth * 100).rounded() / 100
                return band
            }
            $0.gainDB = Float(preset.preampDB)
            $0.presetName = preset.title
        }
    }
}

/// The name of the curve an output plays, and the popover that swaps it for another.
struct PresetButton: View {
    let model: AppModel
    let uid: String

    @State private var isOpen = false

    private var title: String {
        if let name = model.output(uid).presetName { return name }
        // A shape that filters at any gain, such as a low pass, is never flat.
        let flatShapes: [FilterType] = [.parametric, .lowShelf, .highShelf, .resonantLowShelf, .resonantHighShelf]
        let flat = model.output(uid).eq.allSatisfy { band in
            band.bypass || (band.gainDB == 0 && flatShapes.contains(band.type))
        }
        return flat ? "Flat" : "Custom"
    }

    /// Hugs the name; the header truncates it when a long name leaves no room.
    private var label: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down").imageScale(.small)
        }
        .font(.system(size: 11))
    }

    var body: some View {
        Button {
            isOpen = true
        } label: {
            label
        }
        .controlSize(.small)
        .help("Pick a preset for these bands")
        .accessibilityLabel("Preset")
        .accessibilityValue(title)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PresetPicker { preset in
                model.apply(preset, to: uid)
                isOpen = false
            }
        }
    }
}

/// A search field over every AutoEq headphone.
private struct PresetPicker: View {
    let select: (EQPreset) -> Void

    @State private var query = ""
    @FocusState private var isSearching: Bool

    private static let rowLimit = 60

    private var matches: (shown: [EQPreset], hidden: Int) {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let found = PresetLibrary.shared.autoEq.lazy
            .filter { needle.isEmpty || $0.key.contains(needle) }
            .map(\.preset)
        let shown = Array(found.prefix(Self.rowLimit + 1))
        let rest = shown.count > Self.rowLimit ? found.count - Self.rowLimit : 0
        return (Array(shown.prefix(Self.rowLimit)), rest)
    }

    var body: some View {
        let found = matches
        VStack(spacing: 8) {
            TextField("Search headphones", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11))
                .focused($isSearching)
                .accessibilityLabel("Search presets")

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(found.shown) { preset in
                        PresetRow(preset: preset) { select(preset) }
                    }
                    if found.hidden > 0 {
                        Text("\(found.hidden) more")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    if found.shown.isEmpty {
                        Text(PresetLibrary.shared.autoEq.isEmpty ? "Loading" : "No match")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(height: 320)
        }
        .padding(10)
        .frame(width: 320)
        .onAppear { isSearching = true }
    }
}

/// One preset: the headphone, who measured it and what it is.
private struct PresetRow: View {
    let preset: EQPreset
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).font(.system(size: 11)).lineLimit(1)
                Text("\(preset.source), \(preset.form)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovered ? Theme.rowFillHover : .clear, in: .rect(cornerRadius: Theme.glyphRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Preamp \(Readout.decibels(preset.preampDB)) dB")
        .accessibilityLabel(preset.title)
    }
}
