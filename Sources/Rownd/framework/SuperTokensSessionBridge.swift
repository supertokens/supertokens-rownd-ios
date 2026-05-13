import Foundation
import JWTDecode
import SuperTokensIOS

internal enum SuperTokensSessionBridge {
    private static let accessTokenStorageKey = "st-storage-item-st-access-token"
    private static let refreshTokenStorageKey = "st-storage-item-st-refresh-token"
    private static let frontTokenStorageKey = "supertokens-ios-fronttoken-key"
    private static let lastAccessTokenUpdateStorageKey = "st-storage-item-st-last-access-token-update"
    private static let antiCSRFStorageKey = "supertokens-ios-anticsrf-key"

    static func doesSessionExist() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            SuperTokens.doesSessionExist()
        }.value
    }

    static func getAccessToken() async -> String? {
        await Task.detached(priority: .userInitiated) {
            SuperTokens.getAccessToken()
        }.value
    }

    static func attemptRefresh() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            (try? SuperTokens.attemptRefreshingSession()) == true
                && SuperTokens.doesSessionExist()
        }.value
    }

    static func signOut() async {
        await Task.detached(priority: .userInitiated) {
            await withCheckedContinuation { continuation in
                SuperTokens.signOut { _ in
                    continuation.resume()
                }
            }

            clearLocalSessionArtifacts()
        }.value
    }

    // WKWebView requests do not traverse SuperTokensURLProtocol, so Hub-complete
    // auth flows need a direct local session bootstrap.
    static func bootstrapSession(
        accessToken: String,
        refreshToken: String?,
        frontToken: String? = nil,
        antiCSRF: String? = nil
    ) {
        precondition(!Thread.isMainThread, "bootstrapSession must be called off the main thread")
        guard !SuperTokens.doesSessionExist() else { return }

        let userDefaults = UserDefaults.standard
        userDefaults.set(accessToken, forKey: accessTokenStorageKey)

        if let refreshToken, !refreshToken.isEmpty {
            userDefaults.set(refreshToken, forKey: refreshTokenStorageKey)
        }

        if let antiCSRF, !antiCSRF.isEmpty {
            userDefaults.set(antiCSRF, forKey: antiCSRFStorageKey)
        }

        userDefaults.set(frontToken ?? buildFrontToken(from: accessToken), forKey: frontTokenStorageKey)
        userDefaults.set(
            "\(Int64(Date().timeIntervalSince1970 * 1000))",
            forKey: lastAccessTokenUpdateStorageKey
        )
    }

    static func syncRowndAuthStateFromSuperTokens() async {
        guard let accessToken = await getAccessToken() else { return }

        await MainActor.run {
            Context.currentContext.store.dispatch(
                SetAuthState(payload: AuthState(accessToken: accessToken, refreshToken: nil))
            )
        }
    }

    static func buildFrontToken(from accessToken: String) -> String {
        var userId = ""
        var accessTokenExpiry: Int64 = 0

        if let jwt = try? decode(jwt: accessToken) {
            userId = jwt.claim(name: "sub").string ?? jwt.claim(name: "userId").string ?? ""
            let expiration = jwt.expiresAt?.timeIntervalSince1970 ?? 0
            accessTokenExpiry = Int64(expiration * 1000)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: ["uid": userId, "ate": accessTokenExpiry, "up": [String: Any]()] as [String: Any]
        ) else {
            return ""
        }

        return data.base64EncodedString()
    }

    private static func clearLocalSessionArtifacts() {
        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: accessTokenStorageKey)
        userDefaults.removeObject(forKey: refreshTokenStorageKey)
        userDefaults.removeObject(forKey: frontTokenStorageKey)
        userDefaults.removeObject(forKey: lastAccessTokenUpdateStorageKey)
        userDefaults.removeObject(forKey: antiCSRFStorageKey)
    }
}

internal struct SuperTokensSessionBridgeClient {
    var doesSessionExist: () async -> Bool
    var getAccessToken: () async -> String?
    var attemptRefresh: () async -> Bool

    static let live = SuperTokensSessionBridgeClient(
        doesSessionExist: SuperTokensSessionBridge.doesSessionExist,
        getAccessToken: SuperTokensSessionBridge.getAccessToken,
        attemptRefresh: SuperTokensSessionBridge.attemptRefresh
    )
}
