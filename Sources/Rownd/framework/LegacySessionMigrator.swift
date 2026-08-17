import Foundation
import JWTDecode

struct SuperTokensSessionTokens: Equatable {
    let accessToken: String
    let refreshToken: String?
    let frontToken: String?
    let antiCSRF: String?
}

enum LegacySessionMigrationResult: Equatable {
    case migrated(SuperTokensSessionTokens)
    case unauthorized
    case sessionAlreadyExists
}

struct LegacySessionMigrationClient {
    private let apiDomainOverride: String?
    private let apiBasePathOverride: String?
    private let legacyApiDomain: String
    private let session: URLSession
    private let refreshLegacyTokenHandler: ((String) async throws -> TokenResponse)?
    private let migrateHandler: ((String) async throws -> LegacySessionMigrationResult)?

    init(
        apiDomain: String? = nil,
        apiBasePath: String? = nil,
        legacyApiDomain: String = "https://api.rownd.io",
        session: URLSession = .shared,
        refreshLegacyTokenHandler: ((String) async throws -> TokenResponse)? = nil,
        migrateHandler: ((String) async throws -> LegacySessionMigrationResult)? = nil
    ) {
        self.apiDomainOverride = apiDomain
        self.apiBasePathOverride = apiBasePath
        self.legacyApiDomain = legacyApiDomain
        self.session = session
        self.refreshLegacyTokenHandler = refreshLegacyTokenHandler
        self.migrateHandler = migrateHandler
    }

    func refreshLegacyToken(refreshToken: String) async throws -> TokenResponse {
        if let refreshLegacyTokenHandler {
            return try await refreshLegacyTokenHandler(refreshToken)
        }

        guard var components = URLComponents(string: legacyApiDomain) else {
            throw RowndError("Invalid legacy Rownd API domain")
        }

        components.path = "/hub/auth/token"
        guard let url = components.url else {
            throw RowndError("Invalid legacy Rownd token refresh URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TokenRequest(
                refreshToken: refreshToken,
                idToken: nil,
                appId: nil,
                intent: nil,
                intentMismatchBehavior: nil,
                userData: nil,
                instantUserId: nil
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RowndError("Legacy Rownd token refresh returned a non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RowndError("Legacy Rownd token refresh failed with status code \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    func migrate(legacyAccessToken: String) async throws -> LegacySessionMigrationResult {
        if let migrateHandler {
            return try await migrateHandler(legacyAccessToken)
        }

        let supertokens = try Rownd.requireSuperTokensConfig()
        let apiDomain = apiDomainOverride ?? supertokens.apiDomain
        let apiBasePath = apiBasePathOverride ?? supertokens.apiBasePath

        guard var components = URLComponents(string: apiDomain) else {
            throw RowndError("Invalid SuperTokens apiDomain")
        }

        components.path = apiBasePath + "/plugin/rownd/migrate"
        guard let url = components.url else {
            throw RowndError("Invalid Rownd migration URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(legacyAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "rid")
        request.setValue("1.18", forHTTPHeaderField: "fdi-version")
        request.setValue("header", forHTTPHeaderField: "st-auth-mode")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RowndError("Rownd migration returned a non-HTTP response")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let interceptedAccessToken = httpResponse.headerValue(named: "st-access-token")
            guard let accessToken = interceptedAccessToken, !accessToken.isEmpty else {
                await SuperTokensSessionBridge.clearLocalSessionArtifacts(
                    matchingAccessToken: interceptedAccessToken
                )
                throw RowndError("Rownd migration response did not include st-access-token")
            }
            guard let refreshToken = httpResponse.headerValue(named: "st-refresh-token"), !refreshToken.isEmpty else {
                await SuperTokensSessionBridge.clearLocalSessionArtifacts(matchingAccessToken: accessToken)
                throw RowndError("Rownd migration response did not include st-refresh-token")
            }
            guard let frontToken = httpResponse.headerValue(named: "front-token"), !frontToken.isEmpty else {
                await SuperTokensSessionBridge.clearLocalSessionArtifacts(matchingAccessToken: accessToken)
                throw RowndError("Rownd migration response did not include front-token")
            }

            return .migrated(
                SuperTokensSessionTokens(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    frontToken: frontToken,
                    antiCSRF: httpResponse.headerValue(named: "anti-csrf")
                )
            )
        case 401:
            return .unauthorized
        case 409:
            return .sessionAlreadyExists
        default:
            throw RowndError("Rownd migration failed with status code \(httpResponse.statusCode)")
        }
    }
}

struct LegacySessionMigrationDependencies {
    var doesSuperTokensSessionExist: () async -> Bool = SuperTokensSessionBridge.doesSessionExist
    var bootstrapSession: (SuperTokensSessionTokens) async -> Bool = { tokens in
        await Task.detached(priority: .userInitiated) {
            SuperTokensSessionBridge.bootstrapSession(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                frontToken: tokens.frontToken,
                antiCSRF: tokens.antiCSRF,
                allowReplacingExistingSession: false
            )
        }.value
    }
    var syncRowndAuthStateFromSuperTokens: (AuthSessionLease) async -> Bool = {
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(lease: $0)
    }
    var currentRowndAccessToken: () async -> String? = {
        await MainActor.run { Context.currentContext.store.state.auth.accessToken }
    }
    var signOut: () async -> Void = Rownd.signOutForMigrationFailure
    var client: LegacySessionMigrationClient = LegacySessionMigrationClient()
}

enum LegacySessionMigrator {
    private static let coordinator = LegacySessionMigrationCoordinator()

    static func migrateIfNeeded(
        authState: AuthState,
        dependencies: LegacySessionMigrationDependencies = LegacySessionMigrationDependencies()
    ) async {
        let lease = AuthSessionLifecycle.capture(rowndAccessToken: authState.accessToken)
        await coordinator.run {
            await performMigrationIfNeeded(authState: authState, lease: lease, dependencies: dependencies)
        }
    }

    static func cancelInFlightMigration(cleanup: @escaping () async -> Void) async {
        await coordinator.cancelAndPerform(cleanup)
    }

    private static func performMigrationIfNeeded(
        authState: AuthState,
        lease initialLease: AuthSessionLease,
        dependencies: LegacySessionMigrationDependencies
    ) async {
        var lease = initialLease
        guard await isCurrent(lease, dependencies: dependencies) else { return }
        if await dependencies.doesSuperTokensSessionExist() {
            guard await isCurrent(lease, dependencies: dependencies) else { return }
            let didSynchronize = await dependencies.syncRowndAuthStateFromSuperTokens(lease)
            guard !Task.isCancelled, AuthSessionLifecycle.isCurrent(lease) else { return }
            if !didSynchronize {
                logger.warning("Existing SuperTokens session could not be synchronized to Rownd auth state")
            }
            return
        }
        guard var legacyAccessToken = authState.accessToken, !legacyAccessToken.isEmpty else { return }
        guard !isSuperTokensAccessToken(legacyAccessToken) else { return }

        var legacyRefreshToken = authState.refreshToken
        if !isAccessTokenValid(legacyAccessToken) {
            guard let refreshToken = legacyRefreshToken, !refreshToken.isEmpty else {
                if await isCurrent(lease, dependencies: dependencies) {
                    await dependencies.signOut()
                }
                return
            }

            do {
                let refreshed = try await dependencies.client.refreshLegacyToken(refreshToken: refreshToken)
                guard await isCurrent(lease, dependencies: dependencies) else { return }
                guard let refreshedAccessToken = refreshed.accessToken, !refreshedAccessToken.isEmpty else {
                    await dependencies.signOut()
                    return
                }

                legacyAccessToken = refreshedAccessToken
                legacyRefreshToken = refreshed.refreshToken ?? legacyRefreshToken

                await MainActor.run {
                    guard !Task.isCancelled,
                          AuthSessionLifecycle.isCurrent(lease),
                          Context.currentContext.store.state.auth.accessToken == lease.rowndAccessToken else { return }
                    Context.currentContext.store.dispatch(
                        SetAuthState(
                            payload: AuthState(
                                accessToken: legacyAccessToken,
                                refreshToken: legacyRefreshToken,
                                isVerifiedUser: authState.isVerifiedUser,
                                hasPreviouslySignedIn: authState.hasPreviouslySignedIn
                            )
                        )
                    )
                }
                lease = AuthSessionLease(generation: lease.generation, rowndAccessToken: legacyAccessToken)
                guard await isCurrent(lease, dependencies: dependencies) else { return }
            } catch is CancellationError {
                return
            } catch {
                logger.warning("Failed to refresh legacy Rownd session before migration: \(String(describing: error))")
                if await isCurrent(lease, dependencies: dependencies) {
                    await dependencies.signOut()
                }
                return
            }
        }

        do {
            guard await isCurrent(lease, dependencies: dependencies) else { return }
            let result = try await migrateWithRetry(
                legacyAccessToken: legacyAccessToken,
                client: dependencies.client
            )
            guard await isCurrent(lease, dependencies: dependencies) else { return }

            switch result {
            case .migrated(let tokens):
                guard hasCompleteNativeSessionTokens(tokens) else {
                    logger.warning("Skipping SuperTokens session bootstrap because migration returned incomplete session headers")
                    return
                }
                let didBootstrap = await dependencies.bootstrapSession(tokens)
                guard await isCurrent(lease, dependencies: dependencies) else { return }
                guard didBootstrap else {
                    logger.warning("Skipping legacy session migration completion because the SuperTokens session could not be adopted")
                    return
                }
                let didSynchronize = await dependencies.syncRowndAuthStateFromSuperTokens(lease)
                guard !Task.isCancelled, AuthSessionLifecycle.isCurrent(lease) else { return }
                guard didSynchronize else {
                    logger.warning("Skipping legacy session migration completion because Rownd auth could not be synchronized")
                    return
                }
                await clearLegacyRefreshToken(lease: lease)
            case .sessionAlreadyExists:
                let didSynchronize = await dependencies.syncRowndAuthStateFromSuperTokens(lease)
                guard !Task.isCancelled, AuthSessionLifecycle.isCurrent(lease) else { return }
                guard didSynchronize else {
                    logger.warning("Keeping legacy session because no local SuperTokens session could be synchronized")
                    return
                }
                await clearLegacyRefreshToken(lease: lease)
            case .unauthorized:
                if await isCurrent(lease, dependencies: dependencies) {
                    await dependencies.signOut()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Failed to migrate legacy Rownd session: \(String(describing: error))")
        }
    }

    private static func migrateWithRetry(
        legacyAccessToken: String,
        client: LegacySessionMigrationClient
    ) async throws -> LegacySessionMigrationResult {
        do {
            return try await client.migrate(legacyAccessToken: legacyAccessToken)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard error is URLError else {
                throw error
            }
            return try await client.migrate(legacyAccessToken: legacyAccessToken)
        }
    }

    private static func clearLegacyRefreshToken(lease: AuthSessionLease) async {
        await MainActor.run {
            guard !Task.isCancelled,
                  AuthSessionLifecycle.isCurrent(lease),
                  Context.currentContext.store.state.auth.accessToken == lease.rowndAccessToken else { return }
            var authState = Context.currentContext.store.state.auth
            authState.refreshToken = nil
            Context.currentContext.store.dispatch(SetAuthState(payload: authState))
        }
    }

    private static func isCurrent(
        _ lease: AuthSessionLease,
        dependencies: LegacySessionMigrationDependencies
    ) async -> Bool {
        guard !Task.isCancelled, AuthSessionLifecycle.isCurrent(lease) else { return false }
        let currentAccessToken = await dependencies.currentRowndAccessToken()
        guard !Task.isCancelled, AuthSessionLifecycle.isCurrent(lease) else { return false }
        return currentAccessToken == lease.rowndAccessToken
    }

    private static func hasCompleteNativeSessionTokens(_ tokens: SuperTokensSessionTokens) -> Bool {
        !tokens.accessToken.isEmpty
            && tokens.refreshToken?.isEmpty == false
            && tokens.frontToken?.isEmpty == false
    }

    private static func isAccessTokenValid(_ accessToken: String) -> Bool {
        guard let jwt = try? decode(jwt: accessToken), let expiresAt = jwt.expiresAt else {
            return false
        }

        guard let currentDateWithMargin = Calendar.current.date(byAdding: .second, value: 60, to: Date()) else {
            return false
        }

        return currentDateWithMargin < expiresAt
    }

    private static func isSuperTokensAccessToken(_ accessToken: String) -> Bool {
        guard let jwt = try? decode(jwt: accessToken) else { return false }

        return jwt.claim(name: "sessionHandle").string != nil
            || jwt.claim(name: "tId").string != nil
    }
}

private actor LegacySessionMigrationCoordinator {
    private var task: (id: UUID, value: Task<Void, Never>)?
    private var invalidationTask: Task<Void, Never>?

    func cancelAndPerform(_ cleanup: @escaping () async -> Void) async {
        if let invalidationTask {
            await invalidationTask.value
            return
        }

        let activeTask = task?.value
        activeTask?.cancel()
        let invalidationTask = Task {
            await activeTask?.value
            await cleanup()
        }
        self.invalidationTask = invalidationTask
        await invalidationTask.value
        task = nil
        self.invalidationTask = nil
    }

    func run(_ operation: @escaping () async -> Void) async {
        guard invalidationTask == nil else { return }

        if let activeTask = task {
            await activeTask.value.value
            return
        }

        let id = UUID()
        let task = Task {
            await operation()
        }
        self.task = (id, task)
        await task.value
        if self.task?.id == id {
            self.task = nil
        }
    }
}

private extension HTTPURLResponse {
    func headerValue(named name: String) -> String? {
        for (key, value) in allHeaderFields {
            guard let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return value as? String
        }

        return nil
    }
}
