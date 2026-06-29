import Foundation
import JWTDecode
import Security
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

    static func getRefreshToken() -> String? {
        storage().get(refreshTokenStorageKey)
    }

    static func getFrontToken() -> String? {
        storage().get(frontTokenStorageKey)
    }

    static func getAntiCSRF() -> String? {
        storage().get(antiCSRFStorageKey)
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

    static func clearLocalSessionArtifacts() {
        clearLocalSessionArtifactsInCurrentThread()
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
        guard let refreshToken, !refreshToken.isEmpty else {
            logger.warning("Skipping SuperTokens session bootstrap because refresh token is missing")
            return
        }

        let storage = storage()
        guard storage.set(accessTokenStorageKey, value: accessToken),
              storage.set(refreshTokenStorageKey, value: refreshToken) else {
            logger.warning("Skipping SuperTokens session bootstrap because session tokens could not be stored")
            clearLocalSessionArtifactsInCurrentThread()
            return
        }

        if let antiCSRF, !antiCSRF.isEmpty {
            guard storage.set(antiCSRFStorageKey, value: antiCSRF) else {
                logger.warning("SuperTokens session bootstrap could not store anti-CSRF token")
                clearLocalSessionArtifactsInCurrentThread()
                return
            }
        }

        guard storage.set(frontTokenStorageKey, value: frontToken ?? buildFrontToken(from: accessToken)),
              storage.set(lastAccessTokenUpdateStorageKey, value: "\(Int64(Date().timeIntervalSince1970 * 1000))") else {
            logger.warning("Skipping SuperTokens session bootstrap because session metadata could not be stored")
            clearLocalSessionArtifactsInCurrentThread()
            return
        }
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

    private static func clearLocalSessionArtifactsInCurrentThread() {
        let storage = storage()
        storage.remove(accessTokenStorageKey)
        storage.remove(refreshTokenStorageKey)
        storage.remove(frontTokenStorageKey)
        storage.remove(lastAccessTokenUpdateStorageKey)
        storage.remove(antiCSRFStorageKey)

        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: accessTokenStorageKey)
        userDefaults.removeObject(forKey: refreshTokenStorageKey)
        userDefaults.removeObject(forKey: frontTokenStorageKey)
        userDefaults.removeObject(forKey: lastAccessTokenUpdateStorageKey)
        userDefaults.removeObject(forKey: antiCSRFStorageKey)
    }

    private static func storage() -> SuperTokensKeychainSessionStorage {
        let config = try? Rownd.requireSuperTokensConfig()
        return SuperTokensKeychainSessionStorage(
            apiDomain: config?.apiDomain,
            apiBasePath: config?.apiBasePath,
            accessGroup: config?.keychainAccessGroup
        )
    }
}

private struct SuperTokensKeychainSessionStorage {
    private let service: String
    private let accessGroup: String?

    init(apiDomain: String?, apiBasePath: String?, accessGroup: String?) {
        self.service = Self.serviceName(apiDomain: apiDomain, apiBasePath: apiBasePath)
        self.accessGroup = accessGroup
    }

    func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return UserDefaults.standard.string(forKey: key)
        }

        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query = baseQuery(key)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: key)
            return true
        }

        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: key)
            return true
        }

        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if retryStatus == errSecSuccess {
                UserDefaults.standard.removeObject(forKey: key)
                return true
            }
        }

        return false
    }

    func remove(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }

    private static func serviceName(apiDomain: String?, apiBasePath: String?) -> String {
        let defaultService = "io.supertokens.session"
        guard let apiDomain, let apiBasePath else { return defaultService }

        return "\(defaultService).\(normaliseDomain(apiDomain))\(normalisePath(apiBasePath))"
    }

    private static func normaliseDomain(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueWithScheme = trimmedValue.hasPrefix("http://") || trimmedValue.hasPrefix("https://")
            ? trimmedValue
            : "https://\(trimmedValue)"

        guard let components = URLComponents(string: valueWithScheme),
              let scheme = components.scheme,
              let host = components.host else {
            return trimmedValue
        }

        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }

        return "\(scheme)://\(host)"
    }

    private static func normalisePath(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmedValue.hasPrefix("/") ? trimmedValue : "/\(trimmedValue)"
        return path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
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
