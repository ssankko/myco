import AppKit
import MycoEngine
import Observation
import os

/// Finds the newest GitHub release and, on request, swaps this bundle for it and relaunches.
///
/// Trust rests on HTTPS to github.com: the zip carries no signature of its own. The download
/// gets no quarantine flag, so the new copy opens without a Gatekeeper prompt.
@MainActor
@Observable
final class Updater {
    struct Release: Equatable {
        let version: String
        let zip: URL
        let page: URL
    }

    private static let latest = URL(string: "https://api.github.com/repos/ssankko/myco/releases/latest")!
    private static let log = Logger(subsystem: AppModel.appBundleID, category: "update")

    /// The release newer than this app, once one is found.
    private(set) var available: Release?
    private(set) var isWorking = false

    /// Checks now and then once a day. Only the shipped app checks; a test host never does.
    func start() {
        guard Bundle.main.bundleIdentifier == AppModel.appBundleID else { return }
        Task {
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// Replaces the running bundle with the release and relaunches. On any failure the release
    /// page opens instead, so the user can finish by hand.
    func install() {
        guard let release = available, !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await Self.replace(with: release)
                Self.relaunchAfterExit()
                // The engine is stopped here, not by the delegate: a quit that waits for a
                // reply spins a nested run loop, and the stop would never get the main actor.
                if let stop = AppDelegate.stop {
                    AppDelegate.stop = nil
                    await stop()
                }
                NSApplication.shared.terminate(nil)
            } catch {
                Self.log.error("update to \(release.version): \(String(describing: error), privacy: .public)")
                NSWorkspace.shared.open(release.page)
            }
            isWorking = false
        }
    }

    private func check() async {
        guard let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        do {
            var request = URLRequest(url: Self.latest)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard Self.isNewer(version, than: mine),
                let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") })
            else { return }
            available = Release(version: version, zip: zip.browser_download_url, page: release.html_url)
        } catch {
            Self.log.error("check: \(String(describing: error), privacy: .public)")
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        return b.lexicographicallyPrecedes(a)
    }

    /// Unzips into a temporary folder, verifies the version, moves this bundle to the Trash and
    /// puts the new one at the same path. The running process keeps its open files.
    private static func replace(with release: Release) async throws {
        let (download, _) = try await URLSession.shared.download(from: release.zip)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Myco-\(release.version)")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", "-x", "-k", download.path, folder.path)
        let fresh = folder.appendingPathComponent("Myco.app")
        guard let version = Bundle(url: fresh)?.infoDictionary?["CFBundleShortVersionString"] as? String,
            version == release.version
        else { throw UpdateError("the zip holds no Myco.app \(release.version)") }
        let current = Bundle.main.bundleURL
        try FileManager.default.trashItem(at: current, resultingItemURL: nil)
        try FileManager.default.moveItem(at: fresh, to: current)
    }

    /// A shell that outlives this process opens the new bundle once the old one is gone.
    private static func relaunchAfterExit() {
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\""
        _ = try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, Bundle.main.bundlePath])
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = try Process.run(URL(fileURLWithPath: tool), arguments: arguments)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(tool) exited with \(process.terminationStatus)")
        }
    }
}

private struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let html_url: URL
    let assets: [Asset]
}
