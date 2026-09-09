import Foundation
import XCTest

@testable import MycoEngine

final class SettingsTests: XCTestCase {
    func testSettingsSavedBeforeProfilesBecomeTheDefaultProfile() throws {
        let json = #"{"outputs":{"a":{"enabled":true,"gainDB":-3,"monitor":false,"monitorGainDB":0,"syncTrimMilliseconds":0,"eq":[]}},"inputs":{"m":{"enabled":true,"gainDB":0,"muted":false}},"virtualRate":48000,"sync":true,"pinDefaults":false,"launchAtLogin":true}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.profiles.map(\.name), ["Default"])
        XCTAssertEqual(settings.activeProfileID, settings.profiles[0].id)
        XCTAssertEqual(settings.outputs["a"]?.gainDB, -3)
        XCTAssertNil(settings.outputs["a"]?.presetName)
        XCTAssertEqual(settings.enabledInputs, ["m"])
        XCTAssertEqual(settings.virtualRate, 48000)
        XCTAssertTrue(settings.sync)
        XCTAssertFalse(settings.pinDefaults)
        XCTAssertNil(settings.fallbackOutput)
        XCTAssertTrue(settings.showOnlyConnected)
    }

    func testFreshSettingsStartInTheDefaultProfile() {
        let settings = Settings()
        XCTAssertEqual(settings.active.name, "Default")
        XCTAssertEqual(settings.outputs, [:])
    }

    func testProfilesRoundTripThroughJSON() throws {
        var settings = Settings()
        settings.outputs["a"] = OutputSettings()
        settings.outputs["a"]?.enabled = true
        let game = settings.addProfile()
        settings.profiles[1].hotkey = Hotkey(keyCode: 5, modifiers: 0x1E0000, key: "G")
        settings.activeProfileID = game.id
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(back, settings)
        XCTAssertEqual(back.active.name, "Profile 2")
        XCTAssertEqual(back.active.hotkey?.key, "G")
    }

    func testTheActiveProfileHoldsTheDeviceSettings() {
        var settings = Settings()
        settings.outputs["speakers"] = OutputSettings()
        settings.outputs["speakers"]?.enabled = true
        settings.outputs["speakers"]?.gainDB = -6
        settings.inputs["mic"] = InputSettings()
        settings.inputs["mic"]?.enabled = true

        // A new profile starts as a copy, so the volume carries over and can then differ.
        let watching = settings.addProfile()
        settings.activeProfileID = watching.id
        XCTAssertEqual(settings.outputs["speakers"]?.gainDB, -6)
        settings.outputs["speakers"]?.enabled = false
        settings.outputs["hers"] = OutputSettings()
        settings.outputs["hers"]?.enabled = true
        settings.inputs["mic"]?.enabled = false
        XCTAssertEqual(settings.enabledOutputs, ["hers"])
        XCTAssertEqual(settings.enabledInputs, [])

        // Back in Default, everything is as it was.
        settings.activeProfileID = settings.profiles[0].id
        XCTAssertEqual(settings.enabledOutputs, ["speakers"])
        XCTAssertEqual(settings.enabledInputs, ["mic"])
        XCTAssertNil(settings.outputs["hers"])
    }

    func testRemovingProfilesKeepsOneAndFallsBackToTheFirst() {
        var settings = Settings()
        let second = settings.addProfile()
        let third = settings.addProfile()
        XCTAssertEqual(settings.profiles.map(\.name), ["Default", "Profile 2", "Profile 3"])
        settings.activeProfileID = third.id
        settings.removeProfile(third.id)
        XCTAssertEqual(settings.activeProfileID, settings.profiles[0].id)
        settings.removeProfile(second.id)
        settings.removeProfile(settings.profiles[0].id)
        XCTAssertEqual(settings.profiles.count, 1, "the last profile stays")
    }
}
