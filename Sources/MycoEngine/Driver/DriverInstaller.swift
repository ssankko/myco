import CoreAudio
import Foundation

struct DriverInstallerError: Error, CustomStringConvertible {
    let description: String
}

/// Installs, removes and identifies the HAL plug-in.
///
/// The installed version comes from the plug-in object's `'mxvr'` property, so it describes the
/// driver coreaudiod actually loaded; the bundled version comes from the copy inside the app.
enum DriverInstaller {
    static let bundleID = "com.ssankko.myco.driver"
    static let installedPath = "/Library/Audio/Plug-Ins/HAL/Myco.driver"

    /// `'mxvr'`, the version property the driver publishes on its plug-in object.
    private static let versionSelector = AudioObjectPropertySelector(0x6D78_7672)

    static func installedVersion() -> String? {
        //  The type of the object ID is spelled out because the property read is generic and an
        //  optional result would ask the HAL for the wrong size.
        let plugIn: AudioObjectID
        do {
            plugIn = try AudioObjectID.system.value(
                AudioObjectPropertyAddress(kAudioHardwarePropertyTranslateBundleIDToPlugIn),
                qualifier: bundleID as CFString)
        } catch {
            return nil
        }
        guard plugIn != AudioObjectID(kAudioObjectUnknown),
            let version = try? plugIn.string(AudioObjectPropertyAddress(versionSelector)),
            !version.isEmpty
        else { return nil }
        return version
    }

    /// The driver inside the running app bundle, absent when the executable runs outside one.
    static var bundledURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Myco.driver")
    }

    static var bundledVersion: String {
        guard let url = bundledURL,
            let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
            let version = plist["CFBundleShortVersionString"] as? String
        else { return "" }
        return version
    }

    static func status() -> DriverStatus {
        guard let installed = installedVersion() else { return .notInstalled }
        let bundled = bundledVersion
        guard bundled.isEmpty || bundled == installed else {
            return .outdated(installed: installed, bundled: bundled)
        }
        return .ready(version: installed)
    }

    static func install() async throws {
        guard let source = bundledURL, FileManager.default.fileExists(atPath: source.path) else {
            throw DriverInstallerError(description: "the app carries no driver to install")
        }
        try await admin("rm -rf '\(installedPath)' && cp -R '\(source.path)' '\(installedPath)' && killall coreaudiod")
        await settle(expectingInstalled: true)
    }

    static func uninstall() async throws {
        try await admin("rm -rf '\(installedPath)' && killall coreaudiod")
        await settle(expectingInstalled: false)
    }

    /// Runs one shell command through the system's administrator prompt.
    private static func admin(_ command: String) async throws {
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(quoted)\" with administrator privileges"
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DriverInstallerError(
                    description: String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }

    /// coreaudiod comes back a moment after the restart, so the device list is only trusted once
    /// the plug-in has appeared or gone.
    private static func settle(expectingInstalled: Bool) async {
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            if (installedVersion() != nil) == expectingInstalled { return }
        }
    }
}
