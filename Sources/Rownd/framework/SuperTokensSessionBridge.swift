import Foundation
import JWTDecode
import Security
import SuperTokensIOS

internal enum SuperTokensSessionBridge {
    struct StableSessionIdentity: Codable, Equatable, Hashable, Sendable {
        let sessionHandle: String
        let userId: String
        let tenantId: String?
    }

    struct SessionIdentity: Equatable, Sendable {
        let accessToken: String
        let generation: UInt64
        let stable: StableSessionIdentity
    }

    enum ReplacementRowndStateSyncResult: Equatable {
        case profileSynchronized
        case profileUnavailable
    }

    private static let adoptionLock = NSLock()
    // A single serial queue for every core session operation — install, clear,
    // reads, refresh, sign-out. Routing them all through one queue keeps them
    // strictly ordered, so a session installed from one task can never be observed
    // as missing because a concurrent (or orphaned) operation interleaved between
    // the install and a later read. Replaces the previous per-call `Task.detached`,
    // whose independent tasks could race one another.
    private static let sessionQueue = DispatchQueue(label: "io.rownd.supertokens.session", qos: .userInitiated)
    private static var sessionGeneration: UInt64 = 0
    // Only the refresh-token slot is still touched directly, by the adopt-over-
    // existing-session path below (a granular refresh-token swap the core SDK has no
    // primitive for). All other reads/writes/clears go through the core SDK.
    private static let refreshTokenStorageKey = "st-storage-item-st-refresh-token"
    internal static var storageOverride: SuperTokensSessionStorage?

    private static func onSessionQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            sessionQueue.async { continuation.resume(returning: work()) }
        }
    }

    static func doesSessionExist() async -> Bool {
        await onSessionQueue { SuperTokens.doesSessionExist() }
    }

    static func getAccessToken() async -> String? {
        await onSessionQueue { SuperTokens.getAccessToken() }
    }

    static func currentSessionIdentity(matching accessToken: String? = nil) async -> SessionIdentity? {
        await onSessionQueue {
            guard let currentAccessToken = SuperTokens.getAccessToken(),
                  accessToken == nil || currentAccessToken == accessToken,
                  let stable = stableSessionIdentity(from: currentAccessToken) else {
                return nil
            }
            return SessionIdentity(
                accessToken: currentAccessToken,
                generation: sessionGeneration,
                stable: stable
            )
        }
    }

    static func claimCurrentSession(matching stableIdentity: StableSessionIdentity) async -> SessionIdentity? {
        await onSessionQueue {
            guard let accessToken = SuperTokens.getAccessToken(),
                  stableSessionIdentity(from: accessToken) == stableIdentity else {
                return nil
            }
            sessionGeneration &+= 1
            return SessionIdentity(
                accessToken: accessToken,
                generation: sessionGeneration,
                stable: stableIdentity
            )
        }
    }

    static func isCurrentSession(_ identity: SessionIdentity) async -> Bool {
        await onSessionQueue {
            guard sessionGeneration == identity.generation,
                  let accessToken = SuperTokens.getAccessToken() else {
                return false
            }
            return stableSessionIdentity(from: accessToken) == identity.stable
        }
    }

    static func currentTokenVersion(of identity: SessionIdentity) async -> SessionIdentity? {
        await onSessionQueue {
            guard sessionGeneration == identity.generation,
                  let accessToken = SuperTokens.getAccessToken(),
                  stableSessionIdentity(from: accessToken) == identity.stable else {
                return nil
            }
            return SessionIdentity(
                accessToken: accessToken,
                generation: sessionGeneration,
                stable: identity.stable
            )
        }
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
        await attemptRefresh(refreshSession: SuperTokens.attemptRefreshingSession)
    }

    static func attemptRefresh(refreshSession: @escaping () throws -> Bool) async -> Bool {
        await onSessionQueue {
            let previousAccessToken = SuperTokens.getAccessToken()
            let previousStableIdentity = previousAccessToken.flatMap(stableSessionIdentity)
            let refreshSucceeded = (try? refreshSession()) == true
            let currentAccessToken = SuperTokens.getAccessToken()
            let currentStableIdentity = currentAccessToken.flatMap(stableSessionIdentity)
            if currentStableIdentity != previousStableIdentity {
                sessionGeneration &+= 1
            }
            return refreshSucceeded && SuperTokens.doesSessionExist()
        }
    }

    static func signOut() async {
        await onSessionQueue { signOutOnSessionQueue() }
    }

    @discardableResult
    static func signOutIfCurrentSession(
        _ expectedIdentity: SessionIdentity,
        expectedRowndAccessToken: String,
        afterSuperTokensSignOut: () async -> Void = {},
        condition: @escaping () -> Bool = { true }
    ) async -> Bool {
        let didSignOut = await onSessionQueue {
            guard condition(),
                  sessionGeneration == expectedIdentity.generation,
                  let accessToken = SuperTokens.getAccessToken(),
                  stableSessionIdentity(from: accessToken) == expectedIdentity.stable else {
                return false
            }
            signOutOnSessionQueue()
            return true
        }
        guard didSignOut else { return false }

        await afterSuperTokensSignOut()
        return await MainActor.run {
            let store = Context.currentContext.store
            guard tokensBelongToSameSession(
                    store.state.auth.accessToken,
                    expectedRowndAccessToken
                  ) else {
                return false
            }
            store.dispatch(SetAuthState(payload: AuthState()))
            RowndEventEmitter.emit(RowndEvent(event: .signOut))
            return true
        }
    }

    private static func signOutOnSessionQueue() {
        sessionGeneration &+= 1
        // Keep sign-out and its local clear atomic with every other bridge session operation.
        let semaphore = DispatchSemaphore(value: 0)
        SuperTokens.signOut { _ in semaphore.signal() }
        semaphore.wait()
        _ = SuperTokens.clearSessionLocally()
    }

    @discardableResult
    static func clearLocalSessionArtifacts() -> Bool {
        sessionQueue.sync {
            sessionGeneration &+= 1
            return SuperTokens.clearSessionLocally()
        }
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
        // Run the whole bootstrap on the shared session queue so the install and its
        // internal reads/refresh can't interleave with a concurrent read, clear, or
        // sign-out from another task.
        return sessionQueue.sync {
            let succeeded = bootstrapSessionOnQueue(
                accessToken: accessToken,
                refreshToken: refreshToken,
                frontToken: frontToken,
                antiCSRF: antiCSRF,
                allowReplacingExistingSession: allowReplacingExistingSession,
                refreshSession: refreshSession
            )
            if succeeded {
                sessionGeneration &+= 1
            }
            return succeeded
        }
    }

    private static func bootstrapSessionOnQueue(
        accessToken: String,
        refreshToken: String?,
        frontToken: String?,
        antiCSRF: String?,
        allowReplacingExistingSession: Bool,
        refreshSession: () throws -> Bool
    ) -> Bool {
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

    @discardableResult
    static func syncRowndAuthStateFromSuperTokens() async -> Bool {
        await syncRowndAuthStateFromSuperTokens(afterTokenRead: {})
    }

    @discardableResult
    static func syncRowndAuthStateFromSuperTokens(
        afterTokenRead: () async -> Void,
        afterAuthDispatch: () async -> Void = {},
        afterReconciliationDispatch: (Int) async -> Void = { _ in },
        afterTerminalReconciliationDispatch: () async -> Void = {
            await MainActor.run {
                _ = Context.currentContext.store.state.saveImmediately()
            }
        },
        commitIf: @MainActor () -> Bool = { true },
        expectedSessionIdentity: SessionIdentity? = nil,
        reconcileOnSessionChange: Bool = true
    ) async -> Bool {
        let rowndAccessTokenBeforeSync = await MainActor.run {
            Context.currentContext.store.state.auth.accessToken
        }
        guard let snapshot = await onSessionQueue({ () -> SessionIdentity? in
            guard let accessToken = SuperTokens.getAccessToken(),
                  let stable = stableSessionIdentity(from: accessToken) else { return nil }
            return SessionIdentity(
                accessToken: accessToken,
                generation: sessionGeneration,
                stable: stable
            )
        }) else { return false }
        guard expectedSessionIdentity == nil || snapshot == expectedSessionIdentity else { return false }

        let accessToken = snapshot.accessToken
        await afterTokenRead()
        let sessionBeforeDispatch = await onSessionQueue { () -> SessionIdentity? in
            guard let accessToken = SuperTokens.getAccessToken(),
                  let stable = stableSessionIdentity(from: accessToken) else { return nil }
            return SessionIdentity(
                accessToken: accessToken,
                generation: sessionGeneration,
                stable: stable
            )
        }
        guard sessionBeforeDispatch == snapshot else {
            guard reconcileOnSessionChange else { return false }
            await reconcileRowndAuthState(
                replacing: rowndAccessTokenBeforeSync,
                afterDispatch: afterReconciliationDispatch,
                afterTerminalDispatch: afterTerminalReconciliationDispatch,
                firstCommitAlreadyOccurred: false,
                commitIf: commitIf
            )
            return false
        }

        let didDispatch = await MainActor.run {
            let store = Context.currentContext.store
            guard store.state.auth.accessToken == rowndAccessTokenBeforeSync else { return false }
            guard commitIf() else { return false }
            var auth = tokensBelongToSameSession(rowndAccessTokenBeforeSync, accessToken)
                ? store.state.auth
                : AuthState()
            auth.accessToken = accessToken
            auth.refreshToken = nil
            if auth.replacementProfilePendingSessionIdentity != snapshot.stable {
                auth.replacementProfilePendingSessionIdentity = nil
            }
            store.dispatch(SetAuthState(payload: auth))
            return true
        }
        guard didDispatch else { return false }
        await afterAuthDispatch()

        let currentSession = await onSessionQueue { () -> SessionIdentity? in
            guard let accessToken = SuperTokens.getAccessToken(),
                  let stable = stableSessionIdentity(from: accessToken) else { return nil }
            return SessionIdentity(
                accessToken: accessToken,
                generation: sessionGeneration,
                stable: stable
            )
        }
        guard currentSession == snapshot else {
            guard reconcileOnSessionChange else { return false }
            await reconcileRowndAuthState(
                replacing: accessToken,
                afterDispatch: afterReconciliationDispatch,
                afterTerminalDispatch: afterTerminalReconciliationDispatch,
                firstCommitAlreadyOccurred: true,
                commitIf: commitIf
            )
            return false
        }
        return true
    }

    @discardableResult
    static func syncReplacementRowndStateFromSuperTokens(
        expectedAccessToken: String,
        expectedPreviousRowndAccessToken: String?,
        fetchUserData: @escaping (RowndState) async throws -> UserStateResponse? = UserData.fetchReplacementUserData,
        persistState: @escaping @MainActor (RowndState) -> Bool = { $0.saveImmediately() },
        beforeInitialAuthSync: () async -> Void = {},
        afterInitialAuthDispatch: (Int) async -> Void = { _ in }
    ) async throws -> ReplacementRowndStateSyncResult {
        guard let expectedStableIdentity = stableSessionIdentity(from: expectedAccessToken) else {
            throw RowndError("Email verification replacement session was invalid")
        }
        let rowndRelationship = await MainActor.run {
            let rowndAccessToken = Context.currentContext.store.state.auth.accessToken
            return rowndAccessToken == expectedPreviousRowndAccessToken
                || rowndAccessToken == expectedAccessToken
                || tokensBelongToSameSession(
                    rowndAccessToken,
                    expectedPreviousRowndAccessToken
                )
                || tokensBelongToSameSession(rowndAccessToken, expectedAccessToken)
        }
        guard rowndRelationship,
              let sessionIdentity = await claimCurrentSession(matching: expectedStableIdentity),
              let ticket = UserData.fetchCoordinator.begin(
            accessToken: sessionIdentity.accessToken,
            purpose: .replacement
        ) else {
            throw RowndError("Email verification replacement session was superseded")
        }
        defer { UserData.fetchCoordinator.finish(ticket) }

        await beforeInitialAuthSync()
        let synchronizedIdentity = try await synchronizeInitialReplacementAuth(
            sessionIdentity,
            responseAccessToken: expectedAccessToken,
            previousRowndAccessToken: expectedPreviousRowndAccessToken,
            ticket: ticket,
            persistState: persistState,
            afterDispatch: afterInitialAuthDispatch
        )

        guard let synchronizedState = await MainActor.run(body: {
            Context.currentContext.store.state
        }), synchronizedState.auth.accessToken == synchronizedIdentity.accessToken else {
            throw RowndError("Email verification replacement session is missing")
        }

        guard await isCurrentSession(synchronizedIdentity),
              UserData.fetchCoordinator.isCurrent(ticket) else {
            throw RowndError("Email verification replacement session was superseded")
        }

        let userResponse: UserStateResponse?
        var profileFetchError: Error?
        do {
            userResponse = try await fetchUserData(synchronizedState)
        } catch {
            userResponse = nil
            profileFetchError = error
        }

        var currentSessionIdentity = try await synchronizeReplacementTokenVersion(
            sessionIdentity,
            ticket: ticket,
            persistState: persistState
        )

        guard let userResponse else {
            if let profileFetchError {
                logger.error("Email verification replaced the session, but its user profile could not be fetched; it will be retried when the app becomes active: \(String(describing: profileFetchError))")
            } else {
                logger.error("Email verification replaced the session, but its user profile was unavailable; it will be retried when the app becomes active")
            }
            return .profileUnavailable
        }

        guard await isCurrentSession(currentSessionIdentity) else {
            throw RowndError("Email verification replacement session was superseded")
        }
        let profileCommitIdentity = currentSessionIdentity
        let didPersistCanonicalUser = await MainActor.run {
            let store = Context.currentContext.store
            guard UserData.fetchCoordinator.isCurrent(ticket),
                  store.state.auth.accessToken == profileCommitIdentity.accessToken else {
                return false
            }
            var auth = store.state.auth
            guard auth.replacementProfilePendingSessionIdentity == profileCommitIdentity.stable else {
                return false
            }
            auth.replacementProfilePendingSessionIdentity = nil
            store.dispatch(SetAuthState(payload: auth))
            store.dispatch(SetUserState(payload: userResponse.toUserState()))
            return persistState(store.state)
        }

        guard didPersistCanonicalUser else {
            throw RowndError("Email verification could not persist the replacement user profile")
        }
        currentSessionIdentity = try await synchronizeReplacementTokenVersion(
            sessionIdentity,
            ticket: ticket,
            persistState: persistState
        )
        let finalSessionIdentity = currentSessionIdentity
        guard await isCurrentSession(currentSessionIdentity),
              UserData.fetchCoordinator.isCurrent(ticket) else {
            await MainActor.run {
                let store = Context.currentContext.store
                guard UserData.fetchCoordinator.isCurrent(ticket),
                      store.state.auth.accessToken == finalSessionIdentity.accessToken else {
                    return
                }
                store.dispatch(SetUserState(payload: UserState()))
                _ = persistState(store.state)
            }
            throw RowndError("Email verification replacement session was superseded")
        }
        return .profileSynchronized
    }

    private static func synchronizeInitialReplacementAuth(
        _ sessionIdentity: SessionIdentity,
        responseAccessToken: String,
        previousRowndAccessToken: String?,
        ticket: UserProfileFetchCoordinator.Ticket,
        persistState: @escaping @MainActor (RowndState) -> Bool,
        afterDispatch: (Int) async -> Void
    ) async throws -> SessionIdentity {
        for attempt in 0..<4 {
            guard let currentIdentity = await currentTokenVersion(of: sessionIdentity),
                  UserData.fetchCoordinator.isCurrent(ticket) else {
                throw RowndError("Email verification replacement session was superseded")
            }

            let didPersist = await MainActor.run {
                let store = Context.currentContext.store
                let rowndAccessToken = store.state.auth.accessToken
                guard UserData.fetchCoordinator.isCurrent(ticket),
                      rowndAccessToken == previousRowndAccessToken
                        || rowndAccessToken == responseAccessToken
                        || tokensBelongToSameSession(rowndAccessToken, previousRowndAccessToken)
                        || tokensBelongToSameSession(rowndAccessToken, responseAccessToken) else {
                    return false
                }

                var auth = tokensBelongToSameSession(rowndAccessToken, responseAccessToken)
                    ? store.state.auth
                    : AuthState()
                auth.accessToken = currentIdentity.accessToken
                auth.refreshToken = nil
                auth.replacementProfilePendingSessionIdentity = currentIdentity.stable
                store.dispatch(SetAuthState(payload: auth))
                store.dispatch(SetUserState(payload: UserState()))
                return persistState(store.state)
            }
            guard didPersist else {
                throw RowndError("Email verification could not persist the replacement session")
            }

            await afterDispatch(attempt)
            guard let verifiedIdentity = await currentTokenVersion(of: sessionIdentity) else {
                throw RowndError("Email verification replacement session was superseded")
            }
            if verifiedIdentity.accessToken == currentIdentity.accessToken {
                return currentIdentity
            }
        }
        throw RowndError("Email verification replacement session did not stabilize")
    }

    private static func synchronizeReplacementTokenVersion(
        _ sessionIdentity: SessionIdentity,
        ticket: UserProfileFetchCoordinator.Ticket,
        persistState: @escaping @MainActor (RowndState) -> Bool
    ) async throws -> SessionIdentity {
        for _ in 0..<4 {
            guard let currentIdentity = await currentTokenVersion(of: sessionIdentity),
                  UserData.fetchCoordinator.isCurrent(ticket) else {
                throw RowndError("Email verification replacement session was superseded")
            }

            let didPersistCurrentToken = await MainActor.run {
                let store = Context.currentContext.store
                guard UserData.fetchCoordinator.isCurrent(ticket),
                      tokensBelongToSameSession(
                        store.state.auth.accessToken,
                        sessionIdentity.accessToken
                      ) else {
                    return false
                }
                guard store.state.auth.accessToken != currentIdentity.accessToken else {
                    return true
                }

                var auth = store.state.auth
                auth.accessToken = currentIdentity.accessToken
                auth.refreshToken = nil
                store.dispatch(SetAuthState(payload: auth))
                return persistState(store.state)
            }
            guard didPersistCurrentToken,
                  let verifiedIdentity = await currentTokenVersion(of: sessionIdentity) else {
                throw RowndError("Email verification replacement session was superseded")
            }
            if verifiedIdentity.accessToken == currentIdentity.accessToken {
                return currentIdentity
            }
        }
        throw RowndError("Email verification replacement session did not stabilize")
    }

    static func tokensBelongToSameSession(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        guard let lhsIdentity = stableSessionIdentity(from: lhs) else { return false }
        return lhsIdentity == stableSessionIdentity(from: rhs)
    }

    static func stableSessionIdentity(from accessToken: String) -> StableSessionIdentity? {
        guard let jwt = try? decode(jwt: accessToken),
              let sessionHandle = jwt.claim(name: "sessionHandle").string,
              !sessionHandle.isEmpty,
              let userId = jwt.subject ?? jwt.claim(name: "userId").string,
              !userId.isEmpty else {
            return nil
        }
        return StableSessionIdentity(
            sessionHandle: sessionHandle,
            userId: userId,
            tenantId: jwt.claim(name: "tId").string ?? jwt.claim(name: "tenantId").string
        )
    }

    private static func reconcileRowndAuthState(
        replacing expectedAccessToken: String?,
        afterDispatch: (Int) async -> Void,
        afterTerminalDispatch: () async -> Void,
        firstCommitAlreadyOccurred: Bool,
        commitIf: @MainActor () -> Bool
    ) async {
        var expectedAccessToken = expectedAccessToken
        var hasCommittedState = firstCommitAlreadyOccurred
        for attempt in 0..<3 {
            let session = await onSessionQueue {
                (generation: sessionGeneration, accessToken: SuperTokens.getAccessToken())
            }
            let requiresCommitPermission = !hasCommittedState
            let expectedAccessTokenForAttempt = expectedAccessToken
            let didDispatch = await MainActor.run {
                let store = Context.currentContext.store
                guard store.state.auth.accessToken == expectedAccessTokenForAttempt else { return false }
                guard !requiresCommitPermission || commitIf() else { return false }
                var auth = tokensBelongToSameSession(
                    expectedAccessTokenForAttempt,
                    session.accessToken
                ) ? store.state.auth : AuthState()
                auth.accessToken = session.accessToken
                auth.refreshToken = nil
                let stableIdentity = session.accessToken.flatMap(stableSessionIdentity)
                if auth.replacementProfilePendingSessionIdentity != stableIdentity {
                    auth.replacementProfilePendingSessionIdentity = nil
                }
                store.dispatch(SetAuthState(payload: auth))
                return true
            }
            guard didDispatch else { return }
            hasCommittedState = true
            await afterDispatch(attempt)

            let verifiedSession = await onSessionQueue {
                (generation: sessionGeneration, accessToken: SuperTokens.getAccessToken())
            }
            guard verifiedSession.generation != session.generation
                    || verifiedSession.accessToken != session.accessToken else {
                return
            }
            expectedAccessToken = session.accessToken
        }

        let expectedAccessTokenAfterAttempts = expectedAccessToken
        let hasCommittedStateAfterAttempts = hasCommittedState
        let didDispatch = await MainActor.run {
            let store = Context.currentContext.store
            guard store.state.auth.accessToken == expectedAccessTokenAfterAttempts else { return false }
            guard hasCommittedStateAfterAttempts || commitIf() else { return false }
            store.dispatch(SetAuthState(payload: AuthState()))
            return true
        }
        if didDispatch {
            await afterTerminalDispatch()
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
