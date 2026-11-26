import Foundation
import JWTDecode
import Security
import SuperTokensIOS

internal enum SuperTokensSessionBridge {
    struct StableSessionIdentity: Codable, Equatable, Hashable, Sendable {
        let sessionHandle: String
        let userId: String
        let tenantId: String?

        func isReplacement(for owner: Self) -> Bool {
            sessionHandle != owner.sessionHandle && userId == owner.userId && tenantId == owner.tenantId
        }
    }

    struct SessionIdentity: Equatable, Sendable {
        let accessToken: String
        let generation: UInt64
        let stable: StableSessionIdentity
    }

    struct AuthOperationPermit: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    struct VerificationOwnership: Hashable, Sendable {
        fileprivate let epoch: UInt64
    }

    final class SessionAdoptionScope: @unchecked Sendable {
        private let lock = NSLock()
        private var valid = true
        // Accessed only on sessionQueue, including cleanup queued by a successor flight.
        fileprivate var installedIdentity: SessionIdentity?

        var isValid: Bool {
            lock.lock()
            defer { lock.unlock() }
            return valid
        }

        func invalidate() {
            lock.lock()
            valid = false
            lock.unlock()
        }
    }

    enum ReplacementRowndStateSyncResult: Equatable {
        case profileSynchronized
        case profileUnavailable
    }

    enum ServerSessionValidation: Equatable, Sendable {
        case valid
        case revoked
        case superseded
        /// The server could not be reached, so the local session must be kept as is.
        case indeterminate
    }

    private static let adoptionLock = NSLock()
    private static let authOperationLock = NSLock()
    private static var authOperationGeneration: UInt64 = 0
    // Unlike other auth permits, verification is not superseded by starting or
    // cancelling a sign-in attempt, only by installing one or signing out.
    private static var verificationAuthEpoch: UInt64 = 0
    // A single serial queue for every core session operation — install, clear,
    // reads, refresh, sign-out. Routing them all through one queue keeps them
    // strictly ordered, so a session installed from one task can never be observed
    // as missing because a concurrent (or orphaned) operation interleaved between
    // the install and a later read. Replaces the previous per-call `Task.detached`,
    // whose independent tasks could race one another.
    private static let sessionQueue = DispatchQueue(label: "io.rownd.supertokens.session", qos: .userInitiated)
    private static let sessionQueueExecutor = SessionQueueExecutor(queue: sessionQueue)
    private static var sessionGeneration: UInt64 = 0
    // 0.5.4 has no raw access-token getter and no granular refresh-token swap.
    private static let accessTokenStorageKey = "st-storage-item-st-access-token"
    private static let refreshTokenStorageKey = "st-storage-item-st-refresh-token"
    internal static var storageOverride: SuperTokensSessionStorage?

    private static func onSessionQueue<T>(_ work: () -> T) async -> T {
        await sessionQueueExecutor.run(work)
    }

    static func doesSessionExist() async -> Bool {
        await onSessionQueue { SuperTokens.doesSessionExist() }
    }

    static func getAccessToken() async -> String? {
        await onSessionQueue { SuperTokens.getAccessToken() }
    }

    static func getAccessTokenForAuthentication() async throws -> String? {
        let result = await onSessionQueue {
            let token = SuperTokens.getAccessToken()
            return (token: token, canRetry: SuperTokens.getRefreshToken()?.isEmpty == false)
        }
        if result.token == nil && result.canRetry {
            // The native getter suppresses refresh errors. Preserve Rownd's public
            // contract: temporary failures throw, while an absent session returns nil.
            throw AuthenticationError.serverError(details: "Session refresh failed temporarily; retry when the service is available")
        }
        return result.token
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

    static func captureAuthOperationPermit() -> AuthOperationPermit {
        authOperationLock.lock()
        defer { authOperationLock.unlock() }
        return AuthOperationPermit(generation: authOperationGeneration)
    }

    static func invalidateAuthOperationPermits() {
        authOperationLock.lock()
        authOperationGeneration &+= 1
        authOperationLock.unlock()
    }

    static func captureVerificationOwnership() -> VerificationOwnership {
        authOperationLock.lock()
        defer { authOperationLock.unlock() }
        return VerificationOwnership(epoch: verificationAuthEpoch)
    }

    static func ownsVerification(_ ownership: VerificationOwnership) -> Bool {
        ownership == captureVerificationOwnership()
    }

    private static func recordSignIn() {
        authOperationLock.lock()
        verificationAuthEpoch &+= 1
        authOperationLock.unlock()
    }

    static func invalidateForSignOut() {
        authOperationLock.lock()
        authOperationGeneration &+= 1
        verificationAuthEpoch &+= 1
        authOperationLock.unlock()
    }

    @MainActor
    static func captureEmailVerification(endpoint: NativeEmailVerificationEndpoint) -> NativeEmailVerificationStart? {
        guard Rownd.isSuperTokensInitialized, !Rownd.isSigningOut else { return nil }
        let store = Context.currentContext.store
        let storeID = ObjectIdentifier(store)
        let rowndAccessToken = store.state.auth.accessToken
        let ownership = captureVerificationOwnership()
        // Never wait on sessionQueue from the Hub message handler: an SDK refresh on it
        // can be waiting for network. Read credentials directly without validating expiry.
        guard let accessToken = storedAccessToken(endpoint),
              let owner = stableSessionIdentity(from: accessToken),
              let refreshToken = SuperTokens.getRefreshToken(), !refreshToken.isEmpty,
              let frontToken = SuperTokens.getFrontToken(), !frontToken.isEmpty else { return nil }
        let antiCSRF = SuperTokens.getAntiCSRF()
        guard SuperTokens.getRefreshToken() == refreshToken,
              SuperTokens.getFrontToken() == frontToken,
              SuperTokens.getAntiCSRF() == antiCSRF,
              storedAccessToken(endpoint) == accessToken,
              ownsVerification(ownership) else { return nil }
        return NativeEmailVerificationStart(
            ownership: ownership,
            tokens: SuperTokensSessionTokens(
                accessToken: accessToken, refreshToken: refreshToken, frontToken: frontToken, antiCSRF: antiCSRF
            ),
            owner: owner,
            storeID: storeID,
            rowndAccessToken: rowndAccessToken,
            endpoint: endpoint
        )
    }

    private static func storedAccessToken(_ endpoint: NativeEmailVerificationEndpoint) -> String? {
        let storage = storageOverride ?? SuperTokensKeychainSessionStorage(
            apiDomain: endpoint.apiDomain, apiBasePath: endpoint.apiBasePath, accessGroup: endpoint.keychainAccessGroup
        )
        return storage.get(accessTokenStorageKey)
    }

    private static func hasStoredCredentials(_ endpoint: NativeEmailVerificationEndpoint) -> Bool {
        storedAccessToken(endpoint) != nil || SuperTokens.getRefreshToken() != nil || SuperTokens.getFrontToken() != nil
    }

    @MainActor
    static func emailVerificationJoinKey(
        parameters: HubWebViewController.NativeEmailVerificationParameters,
        endpoint: NativeEmailVerificationEndpoint
    ) -> NativeEmailVerificationCoordinator.Key? {
        // A reload can arrive after a concurrent refresh removed S0. The store can
        // identify the existing flight, but must never authorize a new request.
        let store = Context.currentContext.store
        guard Rownd.isSuperTokensInitialized, !Rownd.isSigningOut,
              !hasStoredCredentials(endpoint),
              let owner = store.state.auth.accessToken.flatMap(stableSessionIdentity) else { return nil }
        return .init(parameters: parameters, endpoint: endpoint, owner: owner,
                     ownership: captureVerificationOwnership(), storeID: ObjectIdentifier(store))
    }

    @MainActor
    static func canSendVerification(_ start: NativeEmailVerificationStart) -> Bool {
        start.mayCommit()
            && storedAccessToken(start.endpoint).flatMap(stableSessionIdentity) == start.owner
    }

    enum VerificationReplacementInstallation {
        case installed(SessionIdentity)
        case notReplacement
        case notInstalled
    }

    static func installVerificationReplacement(
        accessToken: String,
        refreshToken: String?,
        frontToken: String?,
        antiCSRF: String?,
        replacing start: NativeEmailVerificationStart
    ) async -> VerificationReplacementInstallation {
        guard let stable = stableSessionIdentity(from: accessToken) else { return .notReplacement }
        guard stable.isReplacement(for: start.owner) else {
            if stable.userId != start.owner.userId || stable.tenantId != start.owner.tenantId {
                logger.warning("Ignoring email verification session for a different user or tenant")
            }
            return .notReplacement
        }
        guard let refreshToken, !refreshToken.isEmpty,
              let frontToken, validatedUserId(accessToken: accessToken, frontToken: frontToken) != nil else {
            return .notInstalled
        }
        let tokens = SuperTokensSessionTokens(
            accessToken: accessToken, refreshToken: refreshToken, frontToken: frontToken, antiCSRF: antiCSRF
        )
        guard await start.mayCommit() else { return .notInstalled }
        return await onSessionQueue {
            let currentOwner = storedAccessToken(start.endpoint).flatMap(stableSessionIdentity)
            guard currentOwner == start.owner || !hasStoredCredentials(start.endpoint),
                  ownsVerification(start.ownership) else { return .notInstalled }
            guard installResponseSession(tokens) else { return .notInstalled }
            sessionGeneration &+= 1
            let identity = SessionIdentity(accessToken: accessToken, generation: sessionGeneration, stable: stable)
            guard ownsVerification(start.ownership) else {
                _ = discardSessionIfCurrentOnQueue(identity, endpoint: start.endpoint)
                return .notInstalled
            }
            return .installed(identity)
        }
    }

    static func isInstalledVerificationSession(
        _ identity: SessionIdentity,
        endpoint: NativeEmailVerificationEndpoint
    ) async -> Bool {
        await onSessionQueue {
            sessionGeneration == identity.generation
                && storedAccessToken(endpoint).flatMap(stableSessionIdentity) == identity.stable
        }
    }

    static func adoptResponseSession(
        _ tokens: SuperTokensSessionTokens,
        permit: AuthOperationPermit,
        scope: SessionAdoptionScope? = nil,
        allowReplacingExistingSession: Bool = true,
        isSignIn: Bool = true,
        installSession: @escaping (SuperTokensSessionTokens) -> Bool = installResponseSession
    ) async -> SuperTokensSessionBridge.SessionIdentity? {
        await onSessionQueue {
            guard isAuthOperationPermitValid(permit),
                  scope?.isValid != false,
                  !tokens.refreshToken.isEmpty,
                  !tokens.frontToken.isEmpty,
                  validatedUserId(
                    accessToken: tokens.accessToken,
                    frontToken: tokens.frontToken
                  ) != nil,
                  let stable = stableSessionIdentity(from: tokens.accessToken),
                  allowReplacingExistingSession || !SuperTokens.doesSessionExist(),
                  installSession(tokens) else {
                return nil
            }

            sessionGeneration &+= 1
            let identity = SessionIdentity(
                accessToken: tokens.accessToken,
                generation: sessionGeneration,
                stable: stable
            )
            scope?.installedIdentity = identity
            guard isAuthOperationPermitValid(permit), scope?.isValid != false else {
                if sessionGeneration == identity.generation,
                   SuperTokens.getAccessToken() == identity.accessToken {
                    sessionGeneration &+= 1
                    _ = SuperTokens.clearSessionLocally()
                }
                return nil
            }
            if isSignIn { recordSignIn() }
            return identity
        }
    }

    @discardableResult
    static func discardSessionIfCurrent(
        _ identity: SessionIdentity,
        endpoint: NativeEmailVerificationEndpoint? = nil
    ) async -> Bool {
        await onSessionQueue {
            discardSessionIfCurrentOnQueue(identity, endpoint: endpoint)
        }
    }

    static func discardSession(in scope: SessionAdoptionScope) async {
        await onSessionQueue {
            guard !scope.isValid, let identity = scope.installedIdentity else { return }
            _ = discardSessionIfCurrentOnQueue(identity)
        }
    }

    private static func discardSessionIfCurrentOnQueue(
        _ identity: SessionIdentity,
        endpoint: NativeEmailVerificationEndpoint? = nil
    ) -> Bool {
        guard sessionGeneration == identity.generation else { return false }
        let token: String?
        if let endpoint {
            token = storedAccessToken(endpoint)
        } else {
            token = SuperTokens.getAccessToken()
        }
        guard let accessToken = token,
              stableSessionIdentity(from: accessToken) == identity.stable else {
            return false
        }
        sessionGeneration &+= 1
        return SuperTokens.clearSessionLocally()
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

    static func validateSessionWithServer(
        _ start: NativeEmailVerificationStart
    ) async -> ServerSessionValidation {
        // The SDK refresh call is synchronous and cannot be cancelled. Bound the
        // email-verification task without interrupting other callers sharing the refresh.
        let (results, continuation) = AsyncStream<ServerSessionValidation>.makeStream()
        let probe = Task {
            continuation.yield(await probeSessionWithServer(start))
            continuation.finish()
        }
        let deadline = Task {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                continuation.yield(.indeterminate)
                continuation.finish()
            } catch {}
        }
        defer {
            probe.cancel()
            deadline.cancel()
        }
        var iterator = results.makeAsyncIterator()
        return await iterator.next() ?? .indeterminate
    }

    private static func probeSessionWithServer(_ start: NativeEmailVerificationStart) async -> ServerSessionValidation {
        await onSessionQueue {
            guard !Task.isCancelled, ownsVerification(start.ownership) else { return .superseded }
            guard hasStoredCredentials(start.endpoint) else { return .revoked }
            guard storedAccessToken(start.endpoint).flatMap(stableSessionIdentity) == start.owner else {
                return .superseded
            }
            let refreshed = (try? SuperTokens.attemptRefreshingSession()) == true
            guard ownsVerification(start.ownership) else { return .superseded }
            // The SDK clears credentials before throwing on 401, but keeps them on a
            // transport error or 5xx. Don't use getters that can trigger another refresh.
            guard hasStoredCredentials(start.endpoint) else { return .revoked }
            guard storedAccessToken(start.endpoint).flatMap(stableSessionIdentity) == start.owner else {
                return .superseded
            }
            return refreshed ? .valid : .indeterminate
        }
    }

    @discardableResult
    static func clearRowndSessionRevokedOnServer(
        _ start: NativeEmailVerificationStart,
        beforeCommit: () async -> Void = {},
        persistState: @escaping @MainActor (RowndState) -> Bool = { $0.saveImmediately() }
    ) async -> Bool {
        guard !hasStoredCredentials(start.endpoint) else { return false }
        await beforeCommit()
        return await MainActor.run {
            let store = Context.currentContext.store
            guard !hasStoredCredentials(start.endpoint),
                  start.mayCommit() else { return false }
            guard let rowndAccessToken = store.state.auth.accessToken else { return true }
            guard commitRowndSessionState(
                    accessToken: nil,
                    stableIdentity: nil,
                    replacing: rowndAccessToken,
                    persistState: persistState
                  ) else {
                return false
            }
            RowndEventEmitter.emit(RowndEvent(event: .signOut))
            return true
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
        condition: () -> Bool = { true }
    ) async -> Bool {
        guard condition() else { return false }
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
        permit: AuthOperationPermit? = nil,
        isSignIn: Bool = false,
        refreshSession: () throws -> Bool = SuperTokens.attemptRefreshingSession
    ) -> Bool {
        precondition(!Thread.isMainThread, "bootstrapSession must be called off the main thread")
        // Run the whole bootstrap on the shared session queue so the install and its
        // internal reads/refresh can't interleave with a concurrent read, clear, or
        // sign-out from another task.
        return sessionQueue.sync {
            if let permit, !isAuthOperationPermitValid(permit) { return false }
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
            if let permit, !isAuthOperationPermitValid(permit) {
                if succeeded {
                    _ = SuperTokens.clearSessionLocally()
                }
                return false
            }
            if succeeded && isSignIn { recordSignIn() }
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
        afterTerminalReconciliationDispatch: () async -> Void = {},
        commitIf: @MainActor () -> Bool = { true },
        expectedSessionIdentity: SessionIdentity? = nil,
        reconcileOnSessionChange: Bool = true,
        isSignIn: Bool = false,
        persistState: @escaping @MainActor (RowndState) -> Bool = { $0.saveImmediately() }
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
        if let expectedSessionIdentity {
            guard snapshot.generation == expectedSessionIdentity.generation,
                  snapshot.stable == expectedSessionIdentity.stable else {
                return false
            }
        }

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
            return await reconcileRowndAuthState(
                replacing: rowndAccessTokenBeforeSync,
                afterDispatch: afterReconciliationDispatch,
                afterTerminalDispatch: afterTerminalReconciliationDispatch,
                firstCommitAlreadyOccurred: false,
                expectedSessionIdentity: expectedSessionIdentity,
                commitIf: commitIf,
                persistState: persistState
            )
        }

        let didDispatch = await MainActor.run {
            guard commitIf() else { return false }
            let didCommit = commitRowndSessionState(
                accessToken: accessToken,
                stableIdentity: snapshot.stable,
                replacing: rowndAccessTokenBeforeSync,
                persistState: persistState
            )
            if didCommit && isSignIn { recordSignIn() }
            return didCommit
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
            return await reconcileRowndAuthState(
                replacing: accessToken,
                afterDispatch: afterReconciliationDispatch,
                afterTerminalDispatch: afterTerminalReconciliationDispatch,
                firstCommitAlreadyOccurred: true,
                expectedSessionIdentity: expectedSessionIdentity,
                commitIf: commitIf,
                persistState: persistState
            )
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
        afterInitialAuthDispatch: (Int) async -> Void = { _ in },
        start: NativeEmailVerificationStart? = nil,
        installedIdentity: SessionIdentity? = nil
    ) async throws -> ReplacementRowndStateSyncResult {
        guard let expectedStableIdentity = stableSessionIdentity(from: expectedAccessToken) else {
            throw RowndError("Email verification replacement session was invalid")
        }
        let followsVerification: @MainActor (String?) -> Bool = { rowndAccessToken in
            rowndAccessToken == expectedPreviousRowndAccessToken
                || rowndAccessToken == expectedAccessToken
                || tokensBelongToSameSession(rowndAccessToken, expectedPreviousRowndAccessToken)
                || tokensBelongToSameSession(rowndAccessToken, expectedAccessToken)
                || start?.mayCommit(issuedAccessToken: expectedAccessToken) == true
        }
        let mayCommit: @MainActor () -> Bool = { start?.mayCommit(issuedAccessToken: expectedAccessToken) ?? true }
        let rowndRelationship = await MainActor.run {
            mayCommit() && followsVerification(Context.currentContext.store.state.auth.accessToken)
        }
        guard rowndRelationship else {
            throw RowndError("Email verification replacement session was superseded")
        }
        let claimedIdentity: SessionIdentity?
        if let installedIdentity {
            claimedIdentity = await currentTokenVersion(of: installedIdentity)
        } else {
            claimedIdentity = await claimCurrentSession(matching: expectedStableIdentity)
        }
        guard let sessionIdentity = claimedIdentity,
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
            ticket: ticket,
            persistState: persistState,
            followsVerification: followsVerification,
            mayCommit: mayCommit,
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
            persistState: persistState,
            mayCommit: mayCommit
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
            guard let state = store.state,
                  mayCommit(),
                  UserData.fetchCoordinator.isCurrent(ticket),
                  state.auth.accessToken == profileCommitIdentity.accessToken else {
                return false
            }
            var auth = state.auth
            guard auth.profileHydrationPendingSessionIdentity == profileCommitIdentity.stable else {
                return false
            }
            auth.profileHydrationPendingSessionIdentity = nil
            let user = userResponse.toUserState()
            var candidate = state
            candidate.auth = auth
            candidate.user = user
            guard persistState(candidate) else { return false }
            store.dispatch(SetAuthState(payload: auth))
            store.dispatch(SetUserState(payload: user))
            return true
        }

        guard didPersistCanonicalUser else {
            throw RowndError("Email verification could not persist the replacement user profile")
        }
        currentSessionIdentity = try await synchronizeReplacementTokenVersion(
            sessionIdentity,
            ticket: ticket,
            persistState: persistState,
            mayCommit: mayCommit
        )
        let finalSessionIdentity = currentSessionIdentity
        guard await isCurrentSession(currentSessionIdentity),
              UserData.fetchCoordinator.isCurrent(ticket) else {
            await MainActor.run {
                let store = Context.currentContext.store
                guard let state = store.state,
                      mayCommit(),
                      UserData.fetchCoordinator.isCurrent(ticket),
                      state.auth.accessToken == finalSessionIdentity.accessToken else {
                    return
                }
                var candidate = state
                candidate.user = UserState()
                guard persistState(candidate) else { return }
                store.dispatch(SetUserState(payload: UserState()))
            }
            throw RowndError("Email verification replacement session was superseded")
        }
        return .profileSynchronized
    }

    private static func synchronizeInitialReplacementAuth(
        _ sessionIdentity: SessionIdentity,
        responseAccessToken: String,
        ticket: UserProfileFetchCoordinator.Ticket,
        persistState: @escaping @MainActor (RowndState) -> Bool,
        followsVerification: @MainActor (String?) -> Bool,
        mayCommit: @MainActor () -> Bool,
        afterDispatch: (Int) async -> Void
    ) async throws -> SessionIdentity {
        for attempt in 0..<4 {
            guard let currentIdentity = await currentTokenVersion(of: sessionIdentity),
                  UserData.fetchCoordinator.isCurrent(ticket) else {
                throw RowndError("Email verification replacement session was superseded")
            }

            let didPersist = await MainActor.run {
                let store = Context.currentContext.store
                guard let state = store.state,
                      mayCommit(),
                      UserData.fetchCoordinator.isCurrent(ticket) else {
                    return false
                }
                let rowndAccessToken = state.auth.accessToken
                // After the first commit the store is on the response session, which still follows.
                guard followsVerification(rowndAccessToken) else {
                    return false
                }

                var auth = tokensBelongToSameSession(rowndAccessToken, responseAccessToken)
                    ? state.auth
                    : AuthState()
                auth.accessToken = currentIdentity.accessToken
                auth.refreshToken = nil
                auth.profileHydrationPendingSessionIdentity = currentIdentity.stable
                auth.hasPreviouslySignedIn = auth.hasPreviouslySignedIn == true
                    || auth.isAuthenticated
                let user = UserState()
                var candidate = state
                candidate.auth = auth
                candidate.user = user
                guard persistState(candidate) else { return false }
                store.dispatch(SetAuthState(payload: auth))
                store.dispatch(SetUserState(payload: user))
                return true
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
        persistState: @escaping @MainActor (RowndState) -> Bool,
        mayCommit: @MainActor () -> Bool
    ) async throws -> SessionIdentity {
        for _ in 0..<4 {
            guard let currentIdentity = await currentTokenVersion(of: sessionIdentity),
                  UserData.fetchCoordinator.isCurrent(ticket) else {
                throw RowndError("Email verification replacement session was superseded")
            }

            let didPersistCurrentToken = await MainActor.run {
                let store = Context.currentContext.store
                guard let state = store.state,
                      mayCommit(),
                      UserData.fetchCoordinator.isCurrent(ticket),
                      tokensBelongToSameSession(
                        state.auth.accessToken,
                        sessionIdentity.accessToken
                      ) else {
                    return false
                }
                guard state.auth.accessToken != currentIdentity.accessToken else {
                    return true
                }

                var auth = state.auth
                auth.accessToken = currentIdentity.accessToken
                auth.refreshToken = nil
                var candidate = state
                candidate.auth = auth
                guard persistState(candidate) else { return false }
                store.dispatch(SetAuthState(payload: auth))
                return true
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
        guard let jwt = AccessTokenDecoder.decode(accessToken),
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
        expectedSessionIdentity: SessionIdentity?,
        commitIf: @MainActor () -> Bool,
        persistState: @escaping @MainActor (RowndState) -> Bool
    ) async -> Bool {
        var expectedAccessToken = expectedAccessToken
        var hasCommittedState = firstCommitAlreadyOccurred
        for attempt in 0..<3 {
            let session = await onSessionQueue {
                (generation: sessionGeneration, accessToken: SuperTokens.getAccessToken())
            }
            let requiresCommitPermission = !hasCommittedState
            let expectedAccessTokenForAttempt = expectedAccessToken
            let didDispatch = await MainActor.run {
                guard !requiresCommitPermission || commitIf() else { return false }
                return commitRowndSessionState(
                    accessToken: session.accessToken,
                    stableIdentity: session.accessToken.flatMap(stableSessionIdentity),
                    replacing: expectedAccessTokenForAttempt,
                    persistState: persistState
                )
            }
            guard didDispatch else { return false }
            hasCommittedState = true
            await afterDispatch(attempt)

            let verifiedSession = await onSessionQueue {
                (generation: sessionGeneration, accessToken: SuperTokens.getAccessToken())
            }
            guard verifiedSession.generation != session.generation
                    || verifiedSession.accessToken != session.accessToken else {
                guard let expectedSessionIdentity,
                      session.generation == expectedSessionIdentity.generation,
                      let accessToken = session.accessToken,
                      let stableIdentity = stableSessionIdentity(from: accessToken),
                      stableIdentity == expectedSessionIdentity.stable else {
                    return false
                }
                let reconciledIdentity = SessionIdentity(
                    accessToken: accessToken,
                    generation: session.generation,
                    stable: stableIdentity
                )
                guard await currentTokenVersion(of: reconciledIdentity)?.accessToken == accessToken else {
                    return false
                }
                return await MainActor.run {
                    commitIf()
                        && Context.currentContext.store.state.auth.accessToken == accessToken
                }
            }
            expectedAccessToken = session.accessToken
        }

        let expectedAccessTokenAfterAttempts = expectedAccessToken
        let hasCommittedStateAfterAttempts = hasCommittedState
        let didDispatch = await MainActor.run {
            guard hasCommittedStateAfterAttempts || commitIf() else { return false }
            return commitRowndSessionState(
                accessToken: nil,
                stableIdentity: nil,
                replacing: expectedAccessTokenAfterAttempts,
                persistState: persistState
            )
        }
        if didDispatch {
            await afterTerminalDispatch()
        }
        return false
    }

    static func buildFrontToken(from accessToken: String) -> String {
        var userId = ""
        var accessTokenExpiry: Int64 = 0

        if let jwt = AccessTokenDecoder.decode(accessToken) {
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
        guard let jwt = AccessTokenDecoder.decode(accessToken),
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

    static func isAuthOperationPermitValid(_ permit: AuthOperationPermit) -> Bool {
        authOperationLock.lock()
        defer { authOperationLock.unlock() }
        return permit.generation == authOperationGeneration
    }

    private static func installResponseSession(_ tokens: SuperTokensSessionTokens) -> Bool {
        SuperTokens.installSession(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            frontToken: tokens.frontToken,
            antiCSRFToken: tokens.antiCSRF
        )
    }

    @MainActor
    private static func commitRowndSessionState(
        accessToken: String?,
        stableIdentity: StableSessionIdentity?,
        replacing expectedAccessToken: String?,
        persistState: (RowndState) -> Bool
    ) -> Bool {
        let store = Context.currentContext.store
        guard let state = store.state,
              state.auth.accessToken == expectedAccessToken else { return false }

        let preservesProfile = tokensBelongToSameSession(expectedAccessToken, accessToken)
        var auth: AuthState
        if preservesProfile {
            auth = state.auth
            if auth.profileHydrationPendingSessionIdentity != stableIdentity {
                auth.profileHydrationPendingSessionIdentity = nil
            }
        } else {
            auth = AuthState(hasPreviouslySignedIn: state.auth.hasPreviouslySignedIn)
            auth.profileHydrationPendingSessionIdentity = stableIdentity
        }
        auth.accessToken = accessToken
        auth.refreshToken = nil
        auth.hasPreviouslySignedIn = auth.hasPreviouslySignedIn == true || auth.isAuthenticated
        var candidate = state
        candidate.auth = auth
        if !preservesProfile {
            candidate.user = UserState()
        }
        guard persistState(candidate) else { return false }
        store.dispatch(SetAuthState(payload: auth))
        if !preservesProfile {
            store.dispatch(SetUserState(payload: UserState()))
        }
        return true
    }

}

private actor SessionQueueExecutor {
    let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func run<T>(_ work: () -> T) -> T {
        queue.sync(execute: work)
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
    var getAccessToken: () async throws -> String?
    var attemptRefresh: () async -> Bool

    static let live = SuperTokensSessionBridgeClient(
        doesSessionExist: SuperTokensSessionBridge.doesSessionExist,
        getAccessToken: SuperTokensSessionBridge.getAccessTokenForAuthentication,
        attemptRefresh: SuperTokensSessionBridge.attemptRefresh
    )
}
