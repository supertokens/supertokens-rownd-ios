import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct LegacySessionMigratorTests {
    @Test func synchronizesWhenSuperTokensSessionAlreadyExists() async throws {
        try await withIsolatedStore {
            var didBootstrap = false
            var syncCount = 0
            var calls = MigrationCalls()
            var dependencies = makeDependencies(calls: calls)
            dependencies.doesSuperTokensSessionExist = { true }
            dependencies.bootstrapSession = { _ in didBootstrap = true; return true }
            dependencies.syncRowndAuthStateFromSuperTokens = { _ in syncCount += 1; return true }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))
            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(!didBootstrap)
            #expect(syncCount == 1)
            #expect(calls.migrateAccessTokens.isEmpty)
            #expect(calls.refreshTokens.isEmpty)
        }
    }

    @Test func validLegacySessionMigratesWithoutLegacyRefresh() async throws {
        try await withIsolatedStore {
            let migratedAccessToken = validLegacyToken()
            var calls = MigrationCalls()
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: "anti-csrf-token"
            ))]

            var bootstrappedTokens: SuperTokensSessionTokens?
            var syncCount = 0
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { tokens in bootstrappedTokens = tokens; return true }
            dependencies.syncRowndAuthStateFromSuperTokens = { _ in syncCount += 1; return true }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))

            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(calls.refreshTokens.isEmpty)
            #expect(calls.migrateAccessTokens.count == 1)
            #expect(bootstrappedTokens == SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: "anti-csrf-token"
            ))
            #expect(syncCount == 1)
            #expect(await currentRefreshToken() == nil)
        }
    }

    @Test func expiredLegacySessionRefreshesThenMigrates() async throws {
        try await withIsolatedStore {
            let refreshedLegacyAccessToken = validLegacyToken()
            let migratedAccessToken = validLegacyToken()
            var calls = MigrationCalls()
            calls.refreshResult = TokenResponse(
                refreshToken: "new-legacy-refresh-token",
                accessToken: refreshedLegacyAccessToken,
                userType: nil,
                appVariantUserType: nil
            )
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: nil
            ))]

            var bootstrappedTokens: SuperTokensSessionTokens?
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { tokens in bootstrappedTokens = tokens; return true }

            await setAuthState(AuthState(accessToken: expiredLegacyToken(), refreshToken: "legacy-refresh-token"))

            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(calls.refreshTokens == ["legacy-refresh-token"])
            #expect(calls.migrateAccessTokens == [refreshedLegacyAccessToken])
            #expect(bootstrappedTokens?.accessToken == migratedAccessToken)
            #expect(await currentRefreshToken() == nil)
        }
    }

    @Test func bootstrapFailureKeepsLegacySession() async throws {
        try await withIsolatedStore {
            var calls = MigrationCalls()
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: validSuperTokensToken(),
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: nil
            ))]

            var syncCount = 0
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { _ in false }
            dependencies.syncRowndAuthStateFromSuperTokens = { _ in syncCount += 1; return true }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))
            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(syncCount == 0)
            #expect(await currentRefreshToken() == "legacy-refresh-token")
        }
    }

    @Test func refreshFailureSignsOut() async throws {
        try await withIsolatedStore {
            var calls = MigrationCalls()
            calls.refreshError = RowndError("refresh failed")

            var signOutCount = 0
            var dependencies = makeDependencies(calls: calls)
            dependencies.signOut = { signOutCount += 1 }

            await setAuthState(AuthState(accessToken: expiredLegacyToken(), refreshToken: "legacy-refresh-token"))
            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(signOutCount == 1)
            #expect(calls.refreshTokens == ["legacy-refresh-token"])
            #expect(calls.migrateAccessTokens.isEmpty)
        }
    }

    @Test func unauthorizedMigrationSignsOut() async throws {
        try await withIsolatedStore {
            var calls = MigrationCalls()
            calls.migrateResults = [.unauthorized]

            var signOutCount = 0
            var dependencies = makeDependencies(calls: calls)
            dependencies.signOut = { signOutCount += 1 }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))
            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(signOutCount == 1)
        }
    }

    @Test func conflictMigrationSyncsExistingSession() async throws {
        try await withIsolatedStore {
            var calls = MigrationCalls()
            calls.migrateResults = [.sessionAlreadyExists]

            var syncCount = 0
            var didBootstrap = false
            var dependencies = makeDependencies(calls: calls)
            dependencies.syncRowndAuthStateFromSuperTokens = { _ in syncCount += 1; return true }
            dependencies.bootstrapSession = { _ in didBootstrap = true; return true }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))

            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(syncCount == 1)
            #expect(!didBootstrap)
            #expect(await currentRefreshToken() == nil)
        }
    }

    @Test func conflictMigrationKeepsLegacyRefreshTokenWhenSynchronizationFails() async throws {
        try await withIsolatedStore {
            var calls = MigrationCalls()
            calls.migrateResults = [.sessionAlreadyExists]

            var dependencies = makeDependencies(calls: calls)
            dependencies.syncRowndAuthStateFromSuperTokens = { _ in false }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))

            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(await currentRefreshToken() == "legacy-refresh-token")
        }
    }

    @Test func migrationNetworkFailureRetriesOnce() async throws {
        try await withIsolatedStore {
            let migratedAccessToken = validLegacyToken()
            var calls = MigrationCalls()
            calls.migrateErrors = [URLError(.notConnectedToInternet)]
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: nil
            ))]

            var bootstrappedTokens: SuperTokensSessionTokens?
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { tokens in bootstrappedTokens = tokens; return true }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))
            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(calls.migrateAccessTokens.count == 2)
            #expect(bootstrappedTokens?.accessToken == migratedAccessToken)
        }
    }

    @Test func migratesLegacyTokenEvenWhenCompatibilityAuthStateRejectsIt() async throws {
        try await withIsolatedStore {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }

            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )

            let legacyAuthState = AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token")
            let migratedAccessToken = validSuperTokensToken()
            var calls = MigrationCalls()
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: nil
            ))]

            var bootstrappedTokens: SuperTokensSessionTokens?
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { tokens in bootstrappedTokens = tokens; return true }

            #expect(!legacyAuthState.isAccessTokenValid)

            await setAuthState(legacyAuthState)
            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            let legacyAccessToken = try #require(legacyAuthState.accessToken)
            #expect(calls.migrateAccessTokens == [legacyAccessToken])
            #expect(bootstrappedTokens?.accessToken == migratedAccessToken)
        }
    }

    @Test func concurrentMigrationCallersShareOneOperation() async throws {
        try await withIsolatedStore {
            let authState = AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token")
            let gate = MigrationGate()
            var dependencies = makeDependencies(calls: MigrationCalls())
            dependencies.client = LegacySessionMigrationClient(migrateHandler: { _ in
                await gate.arrive()
                return .sessionAlreadyExists
            })

            await setAuthState(authState)
            let first = Task {
                await LegacySessionMigrator.migrateIfNeeded(authState: authState, dependencies: dependencies)
            }
            await gate.waitForFirstArrival()

            let second = Task {
                await LegacySessionMigrator.migrateIfNeeded(authState: authState, dependencies: dependencies)
            }
            let third = Task {
                await LegacySessionMigrator.migrateIfNeeded(authState: authState, dependencies: dependencies)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            await gate.release()

            await first.value
            await second.value
            await third.value
            #expect(await gate.arrivalCount == 1)
        }
    }

    private func makeDependencies(calls: MigrationCalls) -> LegacySessionMigrationDependencies {
        LegacySessionMigrationDependencies(
            doesSuperTokensSessionExist: { false },
            bootstrapSession: { _ in true },
            syncRowndAuthStateFromSuperTokens: { _ in true },
            signOut: {},
            client: LegacySessionMigrationClient(
                refreshLegacyTokenHandler: { refreshToken in
                    calls.refreshTokens.append(refreshToken)
                    if let refreshError = calls.refreshError {
                        throw refreshError
                    }
                    return calls.refreshResult ?? TokenResponse(
                        refreshToken: refreshToken,
                        accessToken: validLegacyToken(),
                        userType: nil,
                        appVariantUserType: nil
                    )
                },
                migrateHandler: { accessToken in
                    calls.migrateAccessTokens.append(accessToken)
                    if !calls.migrateErrors.isEmpty {
                        throw calls.migrateErrors.removeFirst()
                    }
                    return calls.migrateResults.isEmpty ? .unauthorized : calls.migrateResults.removeFirst()
                }
            )
        )
    }

    private func withIsolatedStore(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            _ = Context(createStore())
            defer { Context.currentContext = originalContext }

            try await operation()
        }
    }

    @MainActor private func setAuthState(_ authState: AuthState) {
        Context.currentContext.store.dispatch(SetAuthState(payload: authState))
    }

    @MainActor private func currentRefreshToken() -> String? {
        Context.currentContext.store.state.auth.refreshToken
    }

    private func validLegacyToken() -> String {
        generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            appUserId: "app-user-id"
        )
    }

    private func expiredLegacyToken() -> String {
        generateJwt(expires: Date(timeIntervalSinceNow: -3600).timeIntervalSince1970)
    }

    private func validSuperTokensToken() -> String {
        generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "session-handle"
        )
    }
}

private actor MigrationGate {
    private(set) var arrivalCount = 0
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
        arrivalCount += 1
        let continuations = arrivalContinuations
        arrivalContinuations.removeAll()
        continuations.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    func waitForFirstArrival() async {
        guard arrivalCount == 0 else { return }
        await withCheckedContinuation { arrivalContinuations.append($0) }
    }

    func release() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class MigrationCalls: @unchecked Sendable {
    var refreshTokens: [String] = []
    var refreshResult: TokenResponse?
    var refreshError: Error?
    var migrateAccessTokens: [String] = []
    var migrateResults: [LegacySessionMigrationResult] = []
    var migrateErrors: [Error] = []
}
