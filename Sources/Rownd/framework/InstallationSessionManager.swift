import CryptoKit
import Foundation

internal enum InstallationSessionManager {
    private static let rowndStateKey = "RowndState"

    static func prepareForInitialization(config: RowndSuperTokensConfig) throws {
        let markerKey = installationMarkerKey(config: config)
        try prepareForInitialization(
            hasInstallationMarker: Storage.shared.hasInstallationMarker(forKey: markerKey),
            clearLocalData: {
                let didClearSession = SuperTokensSessionBridge.clearLocalSessionArtifacts()
                let didClearState = Storage.shared.remove(forKey: rowndStateKey)
                return didClearSession && didClearState
            },
            writeInstallationMarker: {
                Storage.shared.setInstallationMarker(forKey: markerKey)
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
        clearLocalData: () -> Bool,
        writeInstallationMarker: () -> Bool
    ) throws {
        guard !hasInstallationMarker else { return }

        guard clearLocalData() else {
            throw RowndError("Could not clear session data for a new app installation")
        }

        guard writeInstallationMarker() else {
            throw RowndError("Could not persist the app installation marker")
        }
    }
}
