import Testing

@testable import Rownd

@Suite struct InstallationSessionManagerTests {
    @Test func newInstallationClearsLocalDataBeforeWritingMarker() throws {
        var events: [String] = []

        try InstallationSessionManager.prepareForInitialization(
            hasInstallationMarker: false,
            clearLocalData: {
                events.append("clear")
                return true
            },
            writeInstallationMarker: {
                events.append("mark")
                return true
            }
        )

        #expect(events == ["clear", "mark"])
    }

    @Test func normalRelaunchKeepsSession() throws {
        var didClear = false
        var didWriteMarker = false

        try InstallationSessionManager.prepareForInitialization(
            hasInstallationMarker: true,
            clearLocalData: {
                didClear = true
                return true
            },
            writeInstallationMarker: {
                didWriteMarker = true
                return true
            }
        )

        #expect(!didClear)
        #expect(!didWriteMarker)
    }

    @Test func firstLaunchClearsSession() throws {
        var didClear = false
        var didWriteMarker = false

        try InstallationSessionManager.prepareForInitialization(
            hasInstallationMarker: false,
            clearLocalData: {
                didClear = true
                return true
            },
            writeInstallationMarker: {
                didWriteMarker = true
                return true
            }
        )

        #expect(didClear)
        #expect(didWriteMarker)
    }

    @Test func cleanupFailureDoesNotWriteInstallationMarker() {
        var didWriteMarker = false

        #expect(throws: RowndError.self) {
            try InstallationSessionManager.prepareForInitialization(
                hasInstallationMarker: false,
                clearLocalData: { false },
                writeInstallationMarker: {
                    didWriteMarker = true
                    return true
                }
            )
        }

        #expect(!didWriteMarker)
    }

    @Test func markerWriteFailureThrows() {
        #expect(throws: RowndError.self) {
            try InstallationSessionManager.prepareForInitialization(
                hasInstallationMarker: false,
                clearLocalData: { true },
                writeInstallationMarker: { false }
            )
        }
    }

    @Test func markerIsScopedToSessionStorageIdentity() {
        let firstConfig = RowndSuperTokensConfig(
            appName: "Example",
            apiDomain: "https://first.example.com",
            keychainAccessGroup: "group.example.shared"
        )
        let secondConfig = RowndSuperTokensConfig(
            appName: "Example",
            apiDomain: "https://second.example.com",
            keychainAccessGroup: "group.example.shared"
        )
        let otherAccessGroupConfig = RowndSuperTokensConfig(
            appName: "Example",
            apiDomain: "https://first.example.com",
            keychainAccessGroup: "group.example.other"
        )

        #expect(
            InstallationSessionManager.installationMarkerKey(config: firstConfig)
                != InstallationSessionManager.installationMarkerKey(config: secondConfig)
        )
        #expect(
            InstallationSessionManager.installationMarkerKey(config: firstConfig)
                != InstallationSessionManager.installationMarkerKey(config: otherAccessGroupConfig)
        )
    }

    @Test func unsharedKeychainMarkersAreScopedToBundle() {
        let config = RowndSuperTokensConfig(
            appName: "Example",
            apiDomain: "https://api.example.com"
        )

        #expect(
            InstallationSessionManager.installationMarkerKey(
                config: config,
                bundleIdentifier: "com.example.app"
            ) != InstallationSessionManager.installationMarkerKey(
                config: config,
                bundleIdentifier: "com.example.app.extension"
            )
        )
    }
}
