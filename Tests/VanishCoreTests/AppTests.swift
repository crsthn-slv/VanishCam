import XCTest
@testable import VanishCore

final class AppTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "appsettings-tests-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(suite).plist")
        }
        return UserDefaults(suiteName: suite)!
    }

    func testSettingsStoreRoundTrip() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        var s = AppSettings()
        s.disabledEffects = [.teleport]
        s.holdSeconds = 1.25
        s.calibrationSeconds = 6
        s.cameraName = "FaceTime HD Camera"
        s.cameraIndex = 2
        s.outputWidth = 1920
        s.outputHeight = 1080
        s.soundEnabled = false
        s.soundVolume = 0.3

        var notified: AppSettings?
        store.onChange = { notified = $0 }
        store.settings = s
        XCTAssertEqual(notified?.disabledEffects, [.teleport])

        // a fresh store over the same defaults decodes the same blob
        let reloaded = SettingsStore(defaults: defaults).settings
        XCTAssertEqual(reloaded.disabledEffects, [.teleport])
        XCTAssertEqual(reloaded.enabledEffects, [.dissolve, .substitution])
        XCTAssertEqual(reloaded.holdSeconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(reloaded.calibrationSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(reloaded.cameraName, "FaceTime HD Camera")
        XCTAssertEqual(reloaded.cameraIndex, 2)
        XCTAssertEqual(reloaded.outputWidth, 1920)
        XCTAssertEqual(reloaded.outputHeight, 1080)
        XCTAssertFalse(reloaded.soundEnabled)
        XCTAssertEqual(reloaded.soundVolume, 0.3, accuracy: 0.001)
    }

    func testSettingsStoreUpdateMutatesAndPersists() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update { $0.holdSeconds = 1.75 }
        let reloaded = SettingsStore(defaults: defaults).settings
        XCTAssertEqual(reloaded.holdSeconds, 1.75, accuracy: 0.001)
    }
}
