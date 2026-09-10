import MycoDSP
import MycoEngine
import SwiftUI

/// Every headphone the picker can offer: the AutoEq presets shipped in
/// `Contents/Resources/autoeq.json`, decoded once off the main thread, and the squig.link
/// measurements, listed as they load and fitted when picked.
@MainActor
@Observable
final class PresetLibrary {
    static let shared = PresetLibrary()

    struct Entry: Identifiable {
        let id: String
        let name: String
        let source: String
        let form: String
        /// Name, measurer and variant labels as `searchKey` makes them.
        let key: String
        /// Set for a shipped preset; a squig.link entry is fitted on demand.
        let preset: EQPreset?
        let remote: Squig.Item?
    }

    private(set) var autoEq: [Entry] = []
    private(set) var remote: [Entry] = []
    /// Databases read so far and in total, while the squig.link list is loading.
    private(set) var remoteProgress: (done: Int, total: Int)?

    private init() {
        Task.detached(priority: .utility) {
            guard let url = Bundle.main.url(forResource: "autoeq", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let presets = try? EQPreset.autoEq(from: data) else { return }
            let entries = presets.map {
                Entry(id: $0.id, name: $0.name, source: $0.source, form: $0.form,
                      key: PresetLibrary.searchKey("\($0.name) \($0.source)"), preset: $0, remote: nil)
            }
            await MainActor.run { self.autoEq = entries }
        }
        remoteProgress = (0, 0)
        Task.detached(priority: .utility) {
            let items = await Squig.items { done, total in
                Task { @MainActor in PresetLibrary.shared.remoteProgress = (done, total) }
            }
            let entries = items.map { item in
                let labels = item.variants.compactMap(\.label).joined(separator: " ")
                let key = PresetLibrary.searchKey("\(item.name) \(item.source) \(labels)")
                return Entry(id: item.id, name: item.name, source: item.source, form: item.form,
                             key: key, preset: nil, remote: item)
            }
            await MainActor.run {
                self.remote = entries
                self.remoteProgress = nil
            }
        }
    }

    /// Lowercased words separated by single spaces, with a space in front, so a query word
    /// matches only where a word starts: "3" finds "Pro 3" and not "73dB".
    nonisolated static func searchKey(_ text: String) -> String {
        " " + text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    /// The preset behind `entry`: at hand for a shipped one, fetched and fitted for squig.link,
    /// where `variant` names one measurement and nil takes the item's own choice.
    nonisolated static func preset(for entry: Entry, variant: Squig.Item.Variant? = nil) async throws -> EQPreset {
        if let preset = entry.preset { return preset }
        guard let item = entry.remote else { throw SquigError("nothing to load for \(entry.name)") }
        return try await Squig.preset(for: item, variant: variant)
    }
}

extension AppModel {
    /// A band changed by hand, starting from what plays at the current master: the curve no
    /// longer matches any preset by name and stops following the volume. A write that leaves
    /// the bands as they are, such as a field committing the value it shows, keeps both.
    func editEQ(_ uid: String, _ change: (inout [BandSettings]) -> Void) {
        let played = eqBands(uid)
        var bands = played
        change(&bands)
        guard bands != played else { return }
        updateOutput(uid) {
            $0.eq = bands
            $0.eqVolumes = nil
            $0.presetName = nil
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
            $0.eqVolumes = preset.volumes.isEmpty ? nil : preset.volumes
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

/// A search field over every headphone in the library.
private struct PresetPicker: View {
    let select: (EQPreset) -> Void

    @State private var query = ""
    @FocusState private var isSearching: Bool
    /// The measurement being fetched and fitted, and the one that failed last, as entry id
    /// plus variant file.
    @State private var loading: String?
    @State private var failed: String?
    /// The entries whose variants are unfolded.
    @State private var expanded: Set<String> = []

    private static let rowLimit = 60

    /// Every word of the query has to start a word in the name, the measurer or a variant.
    private var matches: (shown: [PresetLibrary.Entry], hidden: Int) {
        let words = PresetLibrary.searchKey(query).split(separator: " ").map { " \($0)" }
        let library = PresetLibrary.shared
        let found = (library.autoEq + library.remote).lazy
            .filter { entry in words.allSatisfy { entry.key.contains($0) } }
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
                    ForEach(found.shown) { entry in
                        PresetRow(
                            entry: entry, loading: loading, failed: failed,
                            isExpanded: Binding(
                                get: { expanded.contains(entry.id) },
                                set: { if $0 { expanded.insert(entry.id) } else { expanded.remove(entry.id) } })
                        ) { variant in
                            pick(entry, variant: variant)
                        }
                    }
                    if found.hidden > 0 {
                        note("\(found.hidden) more")
                    }
                    if found.shown.isEmpty {
                        note(PresetLibrary.shared.autoEq.isEmpty ? "Loading" : "No match")
                    }
                }
                .padding(.trailing, 10)
            }
            .frame(height: 320)

            if let progress = PresetLibrary.shared.remoteProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading squig.link, \(progress.done) of \(progress.total) databases")
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(width: 320)
        .onAppear { isSearching = true }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    private func pick(_ entry: PresetLibrary.Entry, variant: Squig.Item.Variant?) {
        guard loading == nil else { return }
        let key = PresetRow.key(entry, variant)
        loading = key
        failed = nil
        Task {
            defer { loading = nil }
            do {
                select(try await PresetLibrary.preset(for: entry, variant: variant))
            } catch {
                failed = key
            }
        }
    }
}

/// One headphone: its name, who measured it and what it is. A squig.link one says so, shows its
/// fetch, and unfolds the variants the site measured when there are several.
private struct PresetRow: View {
    let entry: PresetLibrary.Entry
    let loading: String?
    let failed: String?
    @Binding var isExpanded: Bool
    let select: (Squig.Item.Variant?) -> Void

    static func key(_ entry: PresetLibrary.Entry, _ variant: Squig.Item.Variant?) -> String {
        entry.id + (variant?.file ?? "")
    }

    private var variants: [Squig.Item.Variant] { entry.remote?.variants ?? [] }
    private var followsVolume: Bool { (entry.remote?.volumeSet.count ?? 0) >= 2 }

    private var detail: String {
        if failed == Self.key(entry, nil) { return "Could not load the measurement" }
        let site = entry.remote == nil ? entry.source : "\(entry.source) on squig.link"
        var parts = [site, entry.form]
        if variants.count > 1 { parts.append("\(variants.count) variants") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                row(title: entry.name, detail: detail, key: Self.key(entry, nil), followsVolume: followsVolume) {
                    select(nil)
                }
                if variants.count > 1 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .imageScale(.small)
                            .frame(width: 20, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Every measurement the site published")
                    .accessibilityLabel(isExpanded ? "Hide variants" : "Show variants")
                }
            }
            if isExpanded {
                ForEach(variants) { variant in
                    let key = Self.key(entry, variant)
                    row(title: variant.label ?? variant.file,
                        detail: failed == key ? "Could not load the measurement" : nil, key: key) {
                        select(variant)
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .help(entry.preset.map { "Preamp \(Readout.decibels($0.preampDB)) dB" }
            ?? "Fitted to the Harman target when picked")
    }

    private func row(
        title: String, detail: String?, key: String, followsVolume: Bool = false, action: @escaping () -> Void
    ) -> some View {
        HoverRow(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 11)).lineLimit(1)
                        if followsVolume {
                            Image(systemName: "speaker.wave.2")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                                .help("Measured at several volumes: the correction follows the volume slider")
                                .accessibilityLabel("follows the volume")
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(failed == key ? AnyShapeStyle(Theme.caution) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if loading == key {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .accessibilityLabel("\(title) (\(entry.source))")
    }
}

/// A plain button that lights up under the pointer.
private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isHovered ? Theme.rowFillHover : .clear, in: .rect(cornerRadius: Theme.glyphRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
