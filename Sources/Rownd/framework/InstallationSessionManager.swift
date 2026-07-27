import CryptoKit
import Foundation

internal enum InstallationSessionManager {
    struct Preparation {
        let markerKey: String?
        let didClearSuperTokensSession: Bool
    }

    static func prepareForInitialization(config: RowndSuperTokensConfig) throws -> Preparation {
        let markerKey = installationMarkerKey(config: config)
        let didClearSuperTokensSession = try prepareForInitialization(
            hasInstallationMarker: Storage.shared.hasInstallationMarker(forKey: markerKey),
            shouldClearSuperTokensSession: config.clearSessionOnNewInstallation,
            clearSuperTokensSession: SuperTokensSessionBridge.clearLocalSessionArtifacts
        )
        return Preparation(
            markerKey: didClearSuperTokensSession == nil ? nil : markerKey,
            didClearSuperTokensSession: didClearSuperTokensSession == true
        )
    }

    static func completeInitialization(
        _ preparation: Preparation,
        persistPreparedState: (() -> Bool)? = nil
    ) throws {
        try completeInitialization(
            shouldPersistPreparedState: persistPreparedState != nil,
            persistPreparedState: persistPreparedState ?? { true },
            shouldWriteInstallationMarker: preparation.markerKey != nil,
            writeInstallationMarker: {
                guard let markerKey = preparation.markerKey else { return false }
                return Storage.shared.setInstallationMarker(forKey: markerKey)
            }
        )
    }

    static func installationMarkerKey(
        config: RowndSuperTokensConfig,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        let storageAccessIdentity = config.keychainAccessGroup ?? bundleIdentifier ?? "unknown-bundle"
        let identity = [config.apiDomain, config.apiBasePath, storageAccessIdentity].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "io.rownd.sdk.installation-marker.v1-\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    static func prepareForInitialization(
        hasInstallationMarker: Bool,
        shouldClearSuperTokensSession: Bool,
        clearSuperTokensSession: () -> Bool
    ) throws -> Bool? {
        guard !hasInstallationMarker else { return nil }

        guard !shouldClearSuperTokensSession || clearSuperTokensSession() else {
            throw RowndError("Could not clear session data for a new app installation")
        }

        return shouldClearSuperTokensSession
    }

    static func completeInitialization(
        shouldPersistPreparedState: Bool = false,
        persistPreparedState: () -> Bool = { true },
        shouldWriteInstallationMarker: Bool,
        writeInstallationMarker: () -> Bool
    ) throws {
        guard shouldWriteInstallationMarker else { return }
        guard !shouldPersistPreparedState || persistPreparedState() else {
            throw RowndError("Could not persist cleared state for a new app installation")
        }
        guard writeInstallationMarker() else {
            throw RowndError("Could not persist the app installation marker")
        }
    }

    static func authStateAfterPreparation(
        _ authState: AuthState,
        didClearSuperTokensSession: Bool
    ) -> AuthState {
        guard didClearSuperTokensSession,
              AuthState.isSuperTokensAccessToken(authState.accessToken) else {
            return authState
        }

        var clearedAuthState = AuthState()
        clearedAuthState.hasPreviouslySignedIn = authState.hasPreviouslySignedIn
        return clearedAuthState
    }
}
