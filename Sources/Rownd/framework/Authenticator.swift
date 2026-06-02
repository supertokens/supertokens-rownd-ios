//
//  Authenticator.swift
//  Rownd
//
//  Created by Matt Hamann on 10/16/22.
//

import Foundation
import Get
import JWTDecode
import OSLog
import ReSwift

private let log = Logger(subsystem: "io.rownd.sdk", category: "authenticator")

protocol AuthenticatorProtocol {
    func getValidToken() async throws -> AuthState
    func refreshToken() async throws -> AuthState
}

public enum AuthenticationError: Error, LocalizedError, Equatable {
    case noAccessTokenPresent
    case invalidRefreshToken(details: String)
    case networkConnectionFailure(details: String)
    case serverError(details: String)

    public var errorDescription: String? {
        switch self {
        case .noAccessTokenPresent:
            return "No access token present"
        case .invalidRefreshToken(let details):
            return "Invalid refresh token: \(details)"
        case .networkConnectionFailure(let details):
            return "Network connection failure: \(details)"
        case .serverError(let details):
            return "Server error: \(details)"
        }
    }
}

internal let tokenApiConfig = APIClient.Configuration(
    baseURL: URL(string: Rownd.config.apiUrl),
    delegate: TokenApiClientDelegate()
)

internal func tokenApiFactory() -> APIClient {
    return Get.APIClient(configuration: tokenApiConfig)
}

private class TokenApiClientDelegate: APIClientDelegate {
    func client(_ client: APIClient, willSendRequest request: inout URLRequest) async throws {
        request.setValue(
            Constants.TIME_META_HEADER, forHTTPHeaderField: Constants.TIME_META_HEADER_NAME)
        request.setValue(Constants.DEFAULT_API_USER_AGENT, forHTTPHeaderField: "User-Agent")

        let localRequest = request
        log.info(
            "Making request to: \(String(describing: localRequest.httpMethod?.uppercased())) \(String(describing: localRequest.url))"
        )
    }

    // Handle refresh token non-400 response codes
    func client(_ client: APIClient, shouldRetry task: URLSessionTask, error: Error, attempts: Int)
        async throws -> Bool
    {
        if case .unacceptableStatusCode(let statusCode) = error as? APIError,
            statusCode != 400,
            attempts <= 5
        {
            return true
        }

        switch (error as? URLError)?.code {
        case .some(.timedOut),
            .some(.cannotFindHost),
            .some(.cannotConnectToHost),
            .some(.networkConnectionLost),
            .some(.notConnectedToInternet),
            .some(.cancelled),
            .some(.dnsLookupFailed):
            if attempts <= 5 {
                return true
            }
        default: break
        }

        return false
    }
}

// This class exists for the sole purpose of subscribing the Authenticator to the
// global state. Data races can occur when using subscribers within the actor itself,
// which leads to memmory corruption and weird app crashes.
class AuthenticatorSubscription: NSObject {
    private static let inst: AuthenticatorSubscription = AuthenticatorSubscription()
    internal static var currentAuthState: AuthState? = Context.currentContext.store.state.auth

    private override init() {}

    /// This checks the incoming action to determine whether it contains an AuthState payload and pushes that
    /// to the Authenticator if present. This prevents race conditions between the internal Rownd state and any
    /// external subscribers. The Authenticator MUST always reflect the correct state in order to prevent race conditions.
    internal static func createAuthenticatorMiddleware<State>() -> Middleware<State> {
        return { _, _ in
            return { next in
                return { action in
                    var authState: AuthState?

                    switch action {
                    case let action as SetAuthState:
                        authState = action.payload
                    case let action as InitializeRowndState:
                        authState = action.payload.auth
                    default:
                        break
                    }

                    guard let authState = authState else {
                        return next(action)
                    }
                    AuthenticatorSubscription.currentAuthState = authState
                    next(action)
                }
            }
        }
    }
}

actor Authenticator: AuthenticatorProtocol {
    private let sessionBridge: SuperTokensSessionBridgeClient
    private var refreshTask: Task<AuthState, Error>?

    init(sessionBridge: SuperTokensSessionBridgeClient = .live) {
        self.sessionBridge = sessionBridge
    }

    func getValidToken() async throws -> AuthState {
        if let handle = refreshTask {
            return try await handle.value
        }

        guard let accessToken = await sessionBridge.getAccessToken() else {
            throw AuthenticationError.noAccessTokenPresent
        }

        guard isAccessTokenValid(accessToken) else {
            return try await refreshToken()
        }

        return await syncCompatibilityAuthState(accessToken: accessToken)
    }

    func refreshToken() async throws -> AuthState {
        if let refreshTask = refreshTask {
            log.debug("Waiting for token refresh already in progress")
            return try await refreshTask.value
        }

        let task = Task { () throws -> AuthState in
            defer { refreshTask = nil }

            log.debug("Refreshing SuperTokens session...")

            let refreshed = await sessionBridge.attemptRefresh()
            let sessionExists = await sessionBridge.doesSessionExist()
            guard refreshed || sessionExists else {
                throw AuthenticationError.noAccessTokenPresent
            }

            guard let accessToken = await sessionBridge.getAccessToken(), isAccessTokenValid(accessToken) else {
                throw AuthenticationError.noAccessTokenPresent
            }

            log.debug("Successfully refreshed SuperTokens session.")
            return await syncCompatibilityAuthState(accessToken: accessToken)
        }

        self.refreshTask = task

        return try await task.value
    }

    private func syncCompatibilityAuthState(accessToken: String) async -> AuthState {
        let currentAuthState = AuthenticatorSubscription.currentAuthState
            ?? Context.currentContext.store.state.auth
        let isSameAccessToken = currentAuthState.accessToken == accessToken
        let newAuthState = AuthState(
            accessToken: accessToken,
            refreshToken: nil,
            isVerifiedUser: isSameAccessToken ? currentAuthState.isVerifiedUser : nil,
            hasPreviouslySignedIn: currentAuthState.hasPreviouslySignedIn
        )

        AuthenticatorSubscription.currentAuthState = newAuthState

        await MainActor.run {
            // Keep Rownd's compatibility auth state in sync with the SuperTokens session.
            Context.currentContext.store.dispatch(SetAuthState(payload: newAuthState))
        }

        return newAuthState
    }

    private func isAccessTokenValid(_ accessToken: String) -> Bool {
        do {
            let jwt = try decode(jwt: accessToken)
            let currentDate = NetworkTimeManager.shared.currentTime ?? Date()
            guard let expiresAt = jwt.expiresAt,
                let currentDateWithMargin = Calendar.current.date(byAdding: .second, value: 60, to: currentDate)
            else {
                return false
            }

            return !jwt.ntpExpired && currentDateWithMargin < expiresAt
        } catch {
            return false
        }
    }
}
