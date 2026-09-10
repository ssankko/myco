import Foundation
import MycoDSP
import MycoEngine
import OSLog

/// The squig.link measurement databases. One directory lists every site; each site has a phone
/// book per form factor and one text file per measured channel, all static files. They are read
/// on demand and kept under Caches for a week, and a headphone picked from here is fitted to the
/// Harman target on the spot.
enum Squig {
    private static let log = Logger(subsystem: AppModel.appBundleID, category: "squig")
    private static let directory = URL(string: "https://squig.link/squigsites.json")!
    private static let maxAge: TimeInterval = 7 * 24 * 3600
    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(AppModel.appBundleID)/squig", isDirectory: true)
    /// The site AutoEq builds from, so its rows come first.
    static let preferredSource = "Super* Review"

    /// One headphone as one site measured it, with every variant the site published for it.
    struct Item: Sendable, Identifiable {
        var id: String { data.absoluteString + variants[0].file }
        let name: String
        /// The site that measured it.
        let source: String
        let form: String
        let data: URL
        /// Never empty.
        let variants: [Variant]

        /// One measurement file and what sets it apart, such as "(volume: 50% :: firmware: 8A358)".
        struct Variant: Sendable, Identifiable, Equatable {
            var id: String { file }
            let label: String?
            let file: String

            /// The device volume the label names, as a control scalar.
            var volume: Double? {
                guard let match = label?.firstMatch(of: /volume: ([\d.]+)%/), let pct = Double(match.1) else {
                    return nil
                }
                return pct / 100
            }

            /// The label with the volume taken out, what the variants of one volume set share.
            var labelWithoutVolume: String? {
                guard let label else { return nil }
                let rest = label.replacing(/volume: [\d.]+%( :: )?/, with: "")
                    .replacing(/\(\s*\)/, with: "").trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
        }

        /// The variants measured at several volumes and otherwise alike: the largest such set,
        /// the later label on a tie, so a newer firmware wins. Empty when there is no such set.
        var volumeSet: [Variant] {
            let sets = Dictionary(grouping: variants.filter { $0.volume != nil }) { $0.labelWithoutVolume ?? "" }
                .filter { Set($0.value.map(\.volume)).count >= 2 }
            return sets.max { ($0.value.count, $0.key) < ($1.value.count, $1.key) }?.value ?? []
        }
    }

    /// Every headphone in every reachable database, the preferred site first. `progress`
    /// reports databases done and total.
    static func items(progress: @Sendable @escaping (Int, Int) -> Void) async -> [Item] {
        guard let sites = try? JSONDecoder().decode([Site].self, from: await fetch(directory)) else { return [] }
        let books = sites.flatMap { site in
            site.dbs.compactMap { db -> (site: Site, db: Site.Database, form: String)? in
                guard let form = form(of: db.type) else { return nil }
                return (site, db, form)
            }
        }
        var found = [[Item]](repeating: [], count: books.count)
        var done = 0
        await withTaskGroup(of: (Int, [Item]).self) { group in
            var pending = books.indices.makeIterator()
            func start() {
                guard let index = pending.next() else { return }
                let book = books[index]
                group.addTask { (index, await Self.items(site: book.site, folder: book.db.folder, form: book.form)) }
            }
            for _ in 0..<8 { start() }
            for await (index, items) in group {
                found[index] = items
                done += 1
                progress(done, books.count)
                start()
            }
        }
        let items = found.flatMap { $0 }
        return items.filter { $0.source == preferredSource } + items.filter { $0.source != preferredSource }
    }

    private static func items(site: Site, folder: String, form: String) async -> [Item] {
        let path = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = site.base?.appendingPathComponent(path) else { return [] }
        let data = base.appendingPathComponent("data", isDirectory: true)
        do {
            let raw = try await fetch(data.appendingPathComponent("phone_book.json"))
            let book = try JSONDecoder().decode([Brand].self, from: raw)
            return book.flatMap { brand in
                brand.phones.map { phone in
                    let name = "\(brand.name) \(phone.name)"
                    let variants = variants(files: phone.files, suffixes: phone.suffixes, stem: phone.prefix ?? name)
                    return Item(name: name, source: site.name, form: form, data: data, variants: variants)
                }
            }
        } catch {
            log.error("\(data.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// One variant per file, labelled by its suffix. A site that lists several files with no
    /// suffix names the variant in the file itself, after the `stem` the files share.
    static func variants(files: [String], suffixes: [String?], stem: String) -> [Item.Variant] {
        zip(files, suffixes).map { file, suffix in
            var label = suffix
            if label == nil, files.count > 1 {
                let rest = file.lowercased().hasPrefix(stem.lowercased()) ? String(file.dropFirst(stem.count)) : file
                label = rest.trimmingCharacters(in: .whitespaces)
            }
            return Item.Variant(label: label, file: file)
        }
    }

    /// The preset for `variant` of `item`, or for the item itself: its volume set, fitted to
    /// follow the device volume, else its first variant.
    static func preset(for item: Item, variant: Item.Variant? = nil) async throws -> EQPreset {
        let targetName = item.form == "over-ear" ? "target-over-ear" : "target-in-ear"
        guard let targetURL = Bundle.main.url(forResource: targetName, withExtension: "csv"),
              let target = FrequencyCurve(text: try String(contentsOf: targetURL, encoding: .utf8))
        else { throw SquigError("the \(targetName) curve is missing from the app") }
        let steps = variant == nil ? item.volumeSet : []
        if steps.count >= 2 {
            let measured = await withTaskGroup(of: (Double, [FrequencyCurve]).self) { group in
                for step in steps {
                    group.addTask { (step.volume!, await channels(of: step.file, in: item.data)) }
                }
                return await group.reduce(into: [(volume: Double, measurement: [FrequencyCurve])]()) {
                    if !$1.1.isEmpty { $0.append(($1.0, $1.1)) }
                }
            }
            if measured.count >= 2 {
                let label = steps[0].labelWithoutVolume.map { " \($0)" } ?? ""
                return HeadphoneFit.preset(
                    name: item.name + label, source: item.source, form: item.form, volumes: measured, target: target)
            }
        }
        let picked = variant ?? item.variants[0]
        let curves = await channels(of: picked.file, in: item.data)
        guard !curves.isEmpty else { throw SquigError("no measurement file for \(item.name)") }
        let name = item.name + (picked.label.map { " \($0)" } ?? "")
        return HeadphoneFit.preset(
            name: name, source: item.source, form: item.form, measurement: curves, target: target)
    }

    /// The measured channels of one file. Sites name them " L" and " R", " L1" and " R1" when
    /// they publish several seatings, and a lone file when they measured one channel.
    private static func channels(of file: String, in data: URL) async -> [FrequencyCurve] {
        for suffixes in [[" L", " R"], [" L1", " R1"], [""]] {
            let channels = await withTaskGroup(of: FrequencyCurve?.self) { group in
                for suffix in suffixes {
                    group.addTask {
                        let url = data.appendingPathComponent("\(file)\(suffix).txt")
                        guard let data = try? await fetch(url), let text = String(data: data, encoding: .utf8)
                        else { return nil }
                        return FrequencyCurve(text: text)
                    }
                }
                return await group.reduce(into: [FrequencyCurve]()) { if let curve = $1 { $0.append(curve) } }
            }
            if !channels.isEmpty { return channels }
        }
        return []
    }

    /// The bytes at `url`, from the cache while it is under a week old, else from the network.
    /// A network failure falls back to a stale cache when there is one.
    private static func fetch(_ url: URL) async throws -> Data {
        let name = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        let file = cache.appendingPathComponent(name)
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { -$0.timeIntervalSinceNow }
        if let age, age < maxAge, let data = try? Data(contentsOf: file) { return data }
        do {
            var request = URLRequest(url: url)
            request.setValue("Myco", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                throw SquigError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.absoluteString)")
            }
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? data.write(to: file)
            return data
        } catch {
            if let data = try? Data(contentsOf: file) { return data }
            throw error
        }
    }

    private static func form(of type: String) -> String? {
        switch type {
        case "IEMs": "in-ear"
        case "Headphones": "over-ear"
        case "Earbuds": "earbud"
        // 5128 rigs need a target of their own.
        default: nil
        }
    }

    private struct Site: Decodable, Sendable {
        let username: String
        let name: String
        let urlType: String
        let dbs: [Database]

        struct Database: Decodable, Sendable {
            let type: String
            let folder: String
        }

        /// The site on its own domain (graph.hangout.audio) answers file requests from anywhere
        /// but its own page with 403, so it is left out.
        var base: URL? {
            switch urlType {
            case "root": URL(string: "https://squig.link")
            case "labFolder": URL(string: "https://squig.link/lab/\(username)")
            case "altDomain": nil
            default: URL(string: "https://\(username).squig.link")
            }
        }
    }

    private struct Brand: Decodable {
        let name: String
        let phones: [Phone]

        enum CodingKeys: String, CodingKey { case name, phones }

        /// A row the site's own tool would not draw, one with no name or file, is left out.
        init(from decoder: Decoder) throws {
            let row = try decoder.container(keyedBy: CodingKeys.self)
            name = try row.decode(String.self, forKey: .name)
            phones = try row.decode([Lossy<Phone>].self, forKey: .phones).compactMap(\.value)
        }

        /// `file` is one name or a list of variants, each with a suffix that says how it differs.
        /// `prefix` is the part of the file names the variants share.
        struct Phone: Decodable {
            let name: String
            let files: [String]
            let suffixes: [String?]
            let prefix: String?

            enum CodingKeys: String, CodingKey { case name, file, suffix, prefix }

            init(from decoder: Decoder) throws {
                let row = try decoder.container(keyedBy: CodingKeys.self)
                name = try (try? row.decode(String.self, forKey: .name))
                    ?? row.decode([String].self, forKey: .name).first
                    ?? { throw SquigError("a phone with no name") }()
                files = try (try? row.decode(String.self, forKey: .file)).map { [$0] }
                    ?? row.decode([String].self, forKey: .file)
                guard !files.isEmpty else { throw SquigError("a phone with no file") }
                let suffix = (try? row.decode([String].self, forKey: .suffix))
                    ?? (try? row.decode(String.self, forKey: .suffix)).map { [$0] } ?? []
                suffixes = files.indices.map { $0 < suffix.count && !suffix[$0].isEmpty ? suffix[$0] : nil }
                prefix = try? row.decode(String.self, forKey: .prefix)
            }
        }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) { value = try? Value(from: decoder) }
    }
}

struct SquigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
