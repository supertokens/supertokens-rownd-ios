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
            guard let accessToken = httpResponse.headerValue(named: "st-access-token"), !accessToken.isEmpty else {
                SuperTokensSessionBridge.clearLocalSessionArtifacts()
                throw RowndError("Rownd migration response did not include st-access-token")
            }
            guard let refreshToken = httpResponse.headerValue(named: "st-refresh-token"), !refreshToken.isEmpty else {
                SuperTokensSessionBridge.clearLocalSessionArtifacts()
                throw RowndError("Rownd migration response did not include st-refresh-token")
            }
            guard let frontToken = httpResponse.headerValue(named: "front-token"), !frontToken.isEmpty else {
                SuperTokensSessionBridge.clearLocalSessionArtifacts()
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
    var bootstrapSession: (SuperTokensSessionTokens) async -> Void = { tokens in
        await Task.detached(priority: .userInitiated) {
            SuperTokensSessionBridge.bootstrapSession(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                frontToken: tokens.frontToken,
                antiCSRF: tokens.antiCSRF
            )
        }.value
    }
    var syncRowndAuthStateFromSuperTokens: () async -> Void = SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens
    var signOut: () async -> Void = Rownd.signOutForMigrationFailure
    var client: LegacySessionMigrationClient = LegacySessionMigrationClient()
}

enum LegacySessionMigrator {
    private static let coordinator = LegacySessionMigrationCoordinator()

    static func migrateIfNeeded(
        authState: AuthState,
        dependencies: LegacySessionMigrationDependencies = LegacySessionMigrationDependencies()
    ) async {
        await coordinator.run {
            await performMigrationIfNeeded(authState: authState, dependencies: dependencies)
        }
    }

    private static func performMigrationIfNeeded(
        authState: AuthState,
        dependencies: LegacySessionMigrationDependencies
    ) async {
        guard await !dependencies.doesSuperTokensSessionExist() else { return }
        guard var legacyAccessToken = authState.accessToken, !legacyAccessToken.isEmpty else { return }
        guard !isSuperTokensAccessToken(legacyAccessToken) else { return }

        var legacyRefreshToken = authState.refreshToken
        if !isAccessTokenValid(legacyAccessToken) {
            guard let refreshToken = legacyRefreshToken, !refreshToken.isEmpty else {
                await dependencies.signOut()
                return
            }

            do {
                let refreshed = try await dependencies.client.refreshLegacyToken(refreshToken: refreshToken)
                guard let refreshedAccessToken = refreshed.accessToken, !refreshedAccessToken.isEmpty else {
                    await dependencies.signOut()
                    return
                }

                legacyAccessToken = refreshedAccessToken
                legacyRefreshToken = refreshed.refreshToken ?? legacyRefreshToken

                await MainActor.run {
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
            } catch {
                logger.warning("Failed to refresh legacy Rownd session before migration: \(String(describing: error))")
                await dependencies.signOut()
                return
            }
        }

        do {
            let result = try await migrateWithRetry(
                legacyAccessToken: legacyAccessToken,
                client: dependencies.client
            )

            switch result {
            case .migrated(let tokens):
                guard hasCompleteNativeSessionTokens(tokens) else {
                    logger.warning("Skipping SuperTokens session bootstrap because migration returned incomplete session headers")
                    return
                }
                await dependencies.bootstrapSession(tokens)
                await dependencies.syncRowndAuthStateFromSuperTokens()
                await clearLegacyRefreshToken()
            case .sessionAlreadyExists:
                await dependencies.syncRowndAuthStateFromSuperTokens()
                await clearLegacyRefreshToken()
            case .unauthorized:
                await dependencies.signOut()
            }
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
            guard error is URLError else {
                throw error
            }
            return try await client.migrate(legacyAccessToken: legacyAccessToken)
        }
    }

    private static func clearLegacyRefreshToken() async {
        await MainActor.run {
            var authState = Context.currentContext.store.state.auth
            authState.refreshToken = nil
            Context.currentContext.store.dispatch(SetAuthState(payload: authState))
        }
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
    private var task: Task<Void, Never>?

    func run(_ operation: @escaping () async -> Void) async {
        if let task {
            await task.value
            return
        }

        let task = Task {
            await operation()
        }
        self.task = task
        await task.value
        self.task = nil
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
