import Foundation
import JWTDecode
import Security
import SuperTokensIOS

internal enum SuperTokensSessionBridge {
    private static let adoptionLock = NSLock()
    // Only the refresh-token slot is still touched directly, by the adopt-over-
    // existing-session path below (a granular refresh-token swap the core SDK has no
    // primitive for). All other reads/writes/clears go through the core SDK.
    private static let refreshTokenStorageKey = "st-storage-item-st-refresh-token"
    internal static var storageOverride: SuperTokensSessionStorage?

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
        SuperTokens.getRefreshToken()
    }

    static func getFrontToken() -> String? {
        SuperTokens.getFrontToken()
    }

    static func getAntiCSRF() -> String? {
        SuperTokens.getAntiCSRF()
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

            _ = clearLocalSessionArtifacts()
        }.value
    }

    @discardableResult
    static func clearLocalSessionArtifacts() -> Bool {
        SuperTokens.clearSessionLocally()
    }

    // WKWebView requests do not traverse SuperTokensURLProtocol, so Hub-complete
    // auth flows need a direct local session bootstrap.
    static func bootstrapSession(
        accessToken: String,
        refreshToken: String?,
        frontToken: String? = nil,
        antiCSRF: String? = nil,
        allowReplacingExistingSession: Bool = true,
        refreshSession: () throws -> Bool = SuperTokens.attemptRefreshingSession
    ) -> Bool {
        precondition(!Thread.isMainThread, "bootstrapSession must be called off the main thread")
        adoptionLock.lock()
        defer { adoptionLock.unlock() }

        guard let refreshToken, !refreshToken.isEmpty else {
            logger.warning("Skipping SuperTokens session bootstrap because refresh token is missing")
            return false
        }

        let storage = storage()
        let adoptedFrontToken = frontToken ?? buildFrontToken(from: accessToken)
        guard let expectedUserId = validatedUserId(accessToken: accessToken, frontToken: adoptedFrontToken) else {
            logger.warning("Skipping SuperTokens session bootstrap because the session tokens are invalid")
            return false
        }

        let sessionAlreadyExists = SuperTokens.doesSessionExist()
        if sessionAlreadyExists && !allowReplacingExistingSession {
            logger.warning("Skipping SuperTokens session bootstrap because a session already exists")
            return false
        }
        if sessionAlreadyExists,
           SuperTokens.getAccessToken() == accessToken,
           storage.get(refreshTokenStorageKey)?.isEmpty == false {
            return true
        }

        if sessionAlreadyExists {
            let previousAccessToken = SuperTokens.getAccessToken()
            let previousRefreshToken = storage.get(refreshTokenStorageKey)
            guard storage.set(refreshTokenStorageKey, value: refreshToken) else {
                logger.warning("Skipping SuperTokens session bootstrap because the refresh token could not be stored")
                return false
            }

            do {
                guard try refreshSession(),
                      SuperTokens.doesSessionExist(),
                      (try? SuperTokens.getUserId()) == expectedUserId else {
                    logger.warning("SuperTokens did not refresh the adopted session")
                    restoreRefreshTokenIfSessionUnchanged(
                        adoptedValue: refreshToken,
                        previousAccessToken: previousAccessToken,
                        previousValue: previousRefreshToken,
                        storage: storage
                    )
                    return false
                }
            } catch {
                logger.warning("SuperTokens could not refresh the adopted session: \(String(describing: error))")
                restoreRefreshTokenIfSessionUnchanged(
                    adoptedValue: refreshToken,
                    previousAccessToken: previousAccessToken,
                    previousValue: previousRefreshToken,
                    storage: storage
                )
                return false
            }

            return true
        }

        // Greenfield install: there is no existing session to preserve, so write the
        // full token set through the core SDK's own validated path — a single source
        // of truth — instead of re-implementing the keychain writes here.
        // installSession is atomic: it validates the front token, rolls its own
        // storage back on any write failure, and returns true only on a fully
        // successful write. The token identity was already checked by validatedUserId
        // above, so a successful install needs no separate read-back verification.
        guard SuperTokens.installSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            frontToken: adoptedFrontToken,
            antiCSRFToken: antiCSRF
        ) else {
            logger.warning("Skipping SuperTokens session bootstrap because the session could not be installed")
            return false
        }

        return true
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

    private static func validatedUserId(accessToken: String, frontToken: String) -> String? {
        guard let jwt = try? decode(jwt: accessToken),
              let accessTokenUserId = jwt.subject ?? jwt.claim(name: "userId").string,
              !accessTokenUserId.isEmpty,
              jwt.expiresAt.map({ $0 > Date() }) == true,
              jwt.claim(name: "sessionHandle").string != nil || jwt.claim(name: "tId").string != nil,
              let data = Data(base64Encoded: frontToken),
              data.count <= 64 * 1024,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frontTokenUserId = payload["uid"] as? String,
              !frontTokenUserId.isEmpty,
              let accessTokenExpiry = payload["ate"] as? NSNumber,
              accessTokenExpiry.int64Value > Int64(Date().timeIntervalSince1970 * 1000),
              frontTokenUserId == accessTokenUserId else {
            return nil
        }
        return accessTokenUserId
    }

    private static func restoreRefreshTokenIfSessionUnchanged(
        adoptedValue: String,
        previousAccessToken: String?,
        previousValue: String?,
        storage: SuperTokensSessionStorage
    ) {
        guard SuperTokens.doesSessionExist(),
              SuperTokens.getAccessToken() == previousAccessToken,
              storage.get(refreshTokenStorageKey) == adoptedValue else {
            return
        }
        let didRestore = previousValue.map { storage.set(refreshTokenStorageKey, value: $0) }
            ?? storage.remove(refreshTokenStorageKey)
        if !didRestore {
            logger.warning("SuperTokens session bootstrap could not restore the previous refresh token")
        }
    }

    private static func storage() -> SuperTokensSessionStorage {
        if let storageOverride {
            return storageOverride
        }

        let config = try? Rownd.requireSuperTokensConfig()
        return SuperTokensKeychainSessionStorage(
            apiDomain: config?.apiDomain,
            apiBasePath: config?.apiBasePath,
            accessGroup: config?.keychainAccessGroup
        )
    }
}

internal protocol SuperTokensSessionStorage {
    func get(_ key: String) -> String?

    @discardableResult
    func set(_ key: String, value: String) -> Bool

    @discardableResult
    func remove(_ key: String) -> Bool
}

private struct SuperTokensKeychainSessionStorage: SuperTokensSessionStorage {
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

        guard updateStatus == errSecItemNotFound else { return setLegacyFallback(key, value: value) }

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

        return setLegacyFallback(key, value: value)
    }

    @discardableResult
    func remove(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: key)
        return status == errSecSuccess || status == errSecItemNotFound
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

    private func setLegacyFallback(_ key: String, value: String) -> Bool {
        guard accessGroup == nil else { return false }
        UserDefaults.standard.set(value, forKey: key)
        return true
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
        if path == "/" {
            return ""
        }
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
