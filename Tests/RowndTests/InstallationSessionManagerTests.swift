import Foundation
import ReSwift
import Testing

@testable import Rownd

@Suite(.serialized) struct InstallationSessionManagerTests {
    @Test func optedInNewInstallationClearsSuperTokensSessionBeforeWritingMarker() throws {
        var events: [String] = []

        let preparation = try InstallationSessionManager.prepareForInitialization(
            hasInstallationMarker: false,
            shouldClearSuperTokensSession: true,
            clearSuperTokensSession: {
                events.append("clear")
                return true
            }
        )
        try InstallationSessionManager.completeInitialization(
            shouldPersistPreparedState: true,
            persistPreparedState: {
                events.append("persist")
                return true
            },
            shouldWriteInstallationMarker: preparation != nil,
            writeInstallationMarker: {
                events.append("mark")
                return true
            }
        )

        #expect(events == ["clear", "persist", "mark"])
    }

    @Test func defaultConfigurationPreservesSessionAndWritesMarker() throws {
        var didInvokeClear = false
        var didWriteMarker = false

        let preparation = try InstallationSessionManager.prepareForInitialization(
            hasInstallationMarker: false,
            shouldClearSuperTokensSession: false,
            clearSuperTokensSession: {
                didInvokeClear = true
                return true
            }
        )
        try InstallationSessionManager.completeInitialization(
            shouldWriteInstallationMarker: preparation != nil,
            writeInstallationMarker: {
                didWriteMarker = true
                return true
            }
        )

        #expect(!didInvokeClear)
        #expect(didWriteMarker)
    }

    @Test func normalRelaunchKeepsSession() throws {
        var didClear = false
        var didWriteMarker = false

        let preparation = try InstallationSessionManager.prepareForInitialization(
            hasInstallationMarker: true,
            shouldClearSuperTokensSession: true,
            clearSuperTokensSession: {
                didClear = true
                return true
            }
        )
        try InstallationSessionManager.completeInitialization(
            shouldWriteInstallationMarker: preparation != nil,
            writeInstallationMarker: {
                didWriteMarker = true
                return true
            }
        )

        #expect(!didClear)
        #expect(!didWriteMarker)
    }

    @Test func cleanupFailureThrowsBeforeCompletion() {
        #expect(throws: RowndError.self) {
            try InstallationSessionManager.prepareForInitialization(
                hasInstallationMarker: false,
                shouldClearSuperTokensSession: true,
                clearSuperTokensSession: { false }
            )
        }
    }

    @Test func markerWriteFailureThrows() {
        #expect(throws: RowndError.self) {
            try InstallationSessionManager.completeInitialization(
                shouldWriteInstallationMarker: true,
                writeInstallationMarker: { false }
            )
        }
    }

    @Test func statePersistenceFailureDoesNotWriteInstallationMarker() {
        var events: [String] = []

        #expect(throws: RowndError.self) {
            try InstallationSessionManager.completeInitialization(
                shouldPersistPreparedState: true,
                persistPreparedState: {
                    events.append("persist")
                    return false
                },
                shouldWriteInstallationMarker: true,
                writeInstallationMarker: {
                    events.append("mark")
                    return true
                }
            )
        }
        #expect(events == ["persist"])
    }

    @Test func missingNativeSessionClearsOnlySuperTokensCompatibilityAuth() {
        let legacyAuth = AuthState(
            accessToken: generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                appUserId: "app-user-id"
            ),
            refreshToken: "legacy-refresh-token"
        )
        let superTokensAuth = AuthState(
            accessToken: generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "session-handle"
            ),
            hasPreviouslySignedIn: true
        )
        var clearedSuperTokensAuth = AuthState()
        clearedSuperTokensAuth.hasPreviouslySignedIn = true

        #expect(
            InstallationSessionManager.authStateAfterPreparation(
                legacyAuth,
                didClearSuperTokensSession: true
            ) == legacyAuth
        )
        #expect(
            InstallationSessionManager.authStateAfterPreparation(
                superTokensAuth,
                didClearSuperTokensSession: true
            ) == clearedSuperTokensAuth
        )
        #expect(
            InstallationSessionManager.authStateAfterPreparation(
                superTokensAuth,
                didClearSuperTokensSession: false
            ) == superTokensAuth
        )
    }

    @Test func preparedAuthUsesCanonicalStoreStateForPersistence() async {
        let superTokensAuth = AuthState(
            accessToken: generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "session-handle"
            ),
            hasPreviouslySignedIn: true
        )
        let preparedAuth = InstallationSessionManager.authStateAfterPreparation(
            superTokensAuth,
            didClearSuperTokensSession: true
        )
        let user = UserState(
            data: ["user_id": "previous-user"],
            authLevel: .verified
        )
        let initialState = RowndState(auth: superTokensAuth, user: user)
        let store = Store<RowndState>(
            reducer: { action, state in
                var state = state ?? initialState
                state.auth = authReducer(action: action, state: state.auth)
                state.user = userReducer(action: action, state: state.user)
                return state
            },
            state: initialState
        )

        let stateForPersistence = await Rownd.applyPreparedAuthState(
            preparedAuth,
            to: store
        )

        #expect(stateForPersistence == store.state)
        #expect(stateForPersistence?.auth == preparedAuth)
        #expect(stateForPersistence?.user == UserState())
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
