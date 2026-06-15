//
//  AuthTests.swift
//  RowndTests
//
//  Created by Matt Hamann on 9/21/22.
//

import Foundation
import Mocker
import CryptoKit
import Factory
import Get
import ReSwiftThunk
import Combine
import JWTDecode
import Testing

@testable import Rownd

@Suite(.serialized) struct AuthTests {

    init() async throws {
        Container.tokenApi.register {
            APIClient.mock {
                $0.delegate = tokenApiConfig.delegate
            }
        }
        let store = Context.currentContext.store
        await MainActor.run {
            store.dispatch(SetClockSync(clockSyncState: .synced))
        }
        Mocker.removeAll()
    }
    
    @Test func testGetValidTokenReadsSuperTokensAccessToken() async throws {
        let superTokensAccessToken = generateJwt(expires: Date(timeIntervalSinceNow: 1000).timeIntervalSince1970)
        let legacyAuthState = AuthState(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: -1000).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token",
            isVerifiedUser: true,
            hasPreviouslySignedIn: true
        )

        await MainActor.run {
            Context.currentContext.store.dispatch(SetAuthState(payload: legacyAuthState))
        }
        AuthenticatorSubscription.currentAuthState = legacyAuthState

        let bridge = TestSessionBridge(accessToken: superTokensAccessToken)
        let authenticator = Authenticator(sessionBridge: bridge.client)

        let authState = try await authenticator.getValidToken()

        #expect(authState.accessToken == superTokensAccessToken)
        #expect(authState.refreshToken == nil)
        #expect(authState.isVerifiedUser == nil)
        #expect(authState.hasPreviouslySignedIn == true)
        #expect(await bridge.getAccessTokenCalls == 1)
        #expect(await bridge.attemptRefreshCalls == 0)
        #expect(Context.currentContext.store.state.auth.accessToken == superTokensAccessToken)
    }

    @Test func testGetValidTokenDoesNotDependOnRowndRefreshToken() async throws {
        let superTokensAccessToken = generateJwt(expires: Date(timeIntervalSinceNow: 1000).timeIntervalSince1970)
        let legacyAuthState = AuthState(
            accessToken: nil,
            refreshToken: "legacy-refresh-token"
        )

        await MainActor.run {
            Context.currentContext.store.dispatch(SetAuthState(payload: legacyAuthState))
        }
        AuthenticatorSubscription.currentAuthState = legacyAuthState

        let bridge = TestSessionBridge(accessToken: superTokensAccessToken)
        let authenticator = Authenticator(sessionBridge: bridge.client)

        let authState = try await authenticator.getValidToken()

        #expect(authState.accessToken == superTokensAccessToken)
        #expect(authState.refreshToken == nil)
        #expect(await bridge.attemptRefreshCalls == 0)
    }

    @Test func testGetValidTokenRefreshesExpiredSuperTokensAccessToken() async throws {
        let expiredAccessToken = generateJwt(expires: Date(timeIntervalSinceNow: -1000).timeIntervalSince1970)
        let refreshedAccessToken = generateJwt(expires: Date(timeIntervalSinceNow: 1000).timeIntervalSince1970)
        let bridge = TestSessionBridge(
            accessToken: expiredAccessToken,
            sessionExists: true,
            refreshSucceeds: true,
            refreshedAccessToken: refreshedAccessToken
        )
        let authenticator = Authenticator(sessionBridge: bridge.client)

        let authState = try await authenticator.getValidToken()

        #expect(authState.accessToken == refreshedAccessToken)
        #expect(await bridge.attemptRefreshCalls == 1)
    }

    @Test func testGetValidTokenThrowsWhenSuperTokensHasNoToken() async throws {
        let bridge = TestSessionBridge(accessToken: nil, sessionExists: false)
        let authenticator = Authenticator(sessionBridge: bridge.client)

        await #expect(throws: AuthenticationError.noAccessTokenPresent) {
            try await authenticator.getValidToken()
        }
    }

    @Test func testRefreshTokenUsesSuperTokensRefresh() async throws {
        let superTokensAccessToken = generateJwt(expires: Date(timeIntervalSinceNow: 1000).timeIntervalSince1970)
        let bridge = TestSessionBridge(accessToken: superTokensAccessToken, sessionExists: true, refreshSucceeds: true)
        let authenticator = Authenticator(sessionBridge: bridge.client)

        let authState = try await authenticator.refreshToken()

        #expect(authState.accessToken == superTokensAccessToken)
        #expect(authState.refreshToken == nil)
        #expect(await bridge.attemptRefreshCalls == 1)
        #expect(Context.currentContext.store.state.auth.accessToken == superTokensAccessToken)
    }

    @Test func testConcurrentRefreshTokenCallsShareRefreshTask() async throws {
        let superTokensAccessToken = generateJwt(expires: Date(timeIntervalSinceNow: 1000).timeIntervalSince1970)
        let bridge = TestSessionBridge(
            accessToken: superTokensAccessToken,
            sessionExists: true,
            refreshSucceeds: true,
            attemptRefreshDelayNanoseconds: 200_000_000
        )
        let authenticator = Authenticator(sessionBridge: bridge.client)

        async let task1 = authenticator.refreshToken()
        async let task2 = authenticator.refreshToken()
        async let task3 = authenticator.refreshToken()

        let (value1, value2, value3) = try await (task1, task2, task3)

        #expect(value1.accessToken == superTokensAccessToken)
        #expect(value2.accessToken == superTokensAccessToken)
        #expect(value3.accessToken == superTokensAccessToken)
        #expect(await bridge.attemptRefreshCalls == 1)
    }

    @Test func testRowndGetAccessTokenUsesSuperTokensTokenWithoutLegacyRefresh() async throws {
        let superTokensAccessToken = generateJwt(expires: Date(timeIntervalSinceNow: 1000).timeIntervalSince1970)
        let bridge = TestSessionBridge(accessToken: superTokensAccessToken)
        Context.currentContext.authenticator = Authenticator(sessionBridge: bridge.client)

        async let task1 = Rownd.getAccessToken()
        async let task2 = Rownd.getAccessToken()
        async let task3 = Rownd.getAccessToken()

        let (value1, value2, value3) = try await (task1, task2, task3)

        #expect(value1 == superTokensAccessToken)
        #expect(value2 == superTokensAccessToken)
        #expect(value3 == superTokensAccessToken)
        #expect(await bridge.attemptRefreshCalls == 0)
    }

    @Test func testAccessTokenValidWithMargin() async throws {
        let accessTokenNew = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )

        let accessToken65secs = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 65).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )

        let accessTokenOld = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -3600).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )

        let accessToken55secs = AuthState(
            accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 55).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
        )

        #expect(accessTokenNew.isAccessTokenValid == true)
        #expect(accessToken65secs.isAccessTokenValid == true)

        #expect(accessTokenOld.isAccessTokenValid == false)
        #expect(accessToken55secs.isAccessTokenValid == false)
    }

    @Test func superTokensBackedAuthStateRejectsValidLegacyRowndAccessToken() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }

            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )

            let legacyAccessToken = AuthState(
                accessToken: generateJwt(
                    expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                    appUserId: "app-user-id"
                ),
                refreshToken: "legacy-refresh-token"
            )
            let superTokensAccessToken = AuthState(
                accessToken: generateJwt(
                    expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                    sessionHandle: "session-handle"
                )
            )

            #expect(!legacyAccessToken.isAccessTokenValid)
            #expect(superTokensAccessToken.isAccessTokenValid)
        }
    }

    @Test func alwaysThrowWhenAccessTokenCannotBeRetrieved() async throws {
        let store = Context.currentContext.store

        await MainActor.run {
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -3600).timeIntervalSince1970),
                refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
            )))
        }

        let authenticator = TestAuthenticator()
        Context.currentContext.authenticator = authenticator

        // Refresh token has already been used
        authenticator.refreshTokenBehavior = AuthenticationError
            .invalidRefreshToken(details: "Refresh token has been consumed")
        await #expect(
            throws: AuthenticationError.invalidRefreshToken(details: "Refresh token has been consumed")
        ) {
            try await store.state.auth.getAccessToken(throwIfMissing: true)
        }

        authenticator.refreshTokenBehavior = AuthenticationError
            .networkConnectionFailure(details: "Network offline")
        await #expect(
            throws: AuthenticationError.networkConnectionFailure(details: "Network offline")
        ) {
            try await store.state.auth.getAccessToken(throwIfMissing: true)
        }
    }

    @Test func onlyThrowWhenAccessTokenCannotBeRetrievedForNetworkReasons() async throws {
        let store = Context.currentContext.store

        await MainActor.run {
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: -3600).timeIntervalSince1970),
                refreshToken: generateJwt(expires: Date.init().timeIntervalSince1970)
            )))
        }

        let authenticator = TestAuthenticator()
        Context.currentContext.authenticator = authenticator

        // Refresh token has already been used
        authenticator.refreshTokenBehavior = AuthenticationError
            .invalidRefreshToken(details: "Refresh token has been consumed")
        #expect(try await store.state.auth.getAccessToken(throwIfMissing: false) == nil)

        // Network is down
        authenticator.refreshTokenBehavior = AuthenticationError
            .networkConnectionFailure(details: "Network offline")
        await #expect(
            throws: AuthenticationError.networkConnectionFailure(details: "Network offline")
        ) {
            try await store.state.auth.getAccessToken(throwIfMissing: false)
        }
    }
}

struct Header: Encodable {
    let alg = "HS256"
    let typ = "JWT"
}

struct Payload: Encodable {
    var sub = "1234567890"
    var name = "John Doe"
    var iat = 1516239022
    var exp = Int(Date.init().timeIntervalSince1970)
    var sessionHandle: String?
    var appUserId: String?

    enum CodingKeys: String, CodingKey {
        case sub, name, iat, exp, sessionHandle
        case appUserId = "app_user_id"
    }
}

internal func generateJwt(
    expires: TimeInterval,
    sessionHandle: String? = nil,
    appUserId: String? = nil
) -> String {
    let secret = "your-256-bit-secret"
    let privateKey = SymmetricKey(data: Data(secret.utf8))
    
    let headerJSONData = try! JSONEncoder().encode(Header())
    let headerBase64String = headerJSONData.urlSafeBase64EncodedString()
    
    var payload = Payload()
    payload.exp = Int(expires)
    payload.sessionHandle = sessionHandle
    payload.appUserId = appUserId
    let payloadJSONData = try! JSONEncoder().encode(payload)
    let payloadBase64String = payloadJSONData.urlSafeBase64EncodedString()
    
    let toSign = Data((headerBase64String + "." + payloadBase64String).utf8)
    
    let signature = HMAC<SHA256>.authenticationCode(for: toSign, using: privateKey)
    let signatureBase64String = Data(signature).urlSafeBase64EncodedString()
    
    let token = [headerBase64String, payloadBase64String, signatureBase64String].joined(separator: ".")
    return token
}

extension Data {
    func urlSafeBase64EncodedString() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

class TestAuthenticator: AuthenticatorProtocol {

    public var refreshTokenBehavior: AuthenticationError?

    func getValidToken() async throws -> AuthState {
        return try await refreshToken()
    }

    func refreshToken() async throws -> AuthState {
        guard let refreshTokenBehavior = refreshTokenBehavior else {
            return AuthState()
        }

        throw refreshTokenBehavior
    }


}

final class TestSessionBridge {
    private let lock = NSLock()
    private var accessToken: String?
    private let sessionExists: Bool
    private let refreshSucceeds: Bool
    private let refreshedAccessToken: String?
    private let attemptRefreshDelayNanoseconds: UInt64
    private var _getAccessTokenCalls = 0
    private var _attemptRefreshCalls = 0

    init(
        accessToken: String?,
        sessionExists: Bool = true,
        refreshSucceeds: Bool = false,
        refreshedAccessToken: String? = nil,
        attemptRefreshDelayNanoseconds: UInt64 = 0
    ) {
        self.accessToken = accessToken
        self.sessionExists = sessionExists
        self.refreshSucceeds = refreshSucceeds
        self.refreshedAccessToken = refreshedAccessToken
        self.attemptRefreshDelayNanoseconds = attemptRefreshDelayNanoseconds
    }

    var client: SuperTokensSessionBridgeClient {
        SuperTokensSessionBridgeClient(
            doesSessionExist: { [weak self] in
                self?.sessionExists ?? false
            },
            getAccessToken: { [weak self] in
                self?.getAccessToken()
            },
            attemptRefresh: { [weak self] in
                await self?.attemptRefresh() ?? false
            }
        )
    }

    var getAccessTokenCalls: Int {
        get async {
            lock.withLock { _getAccessTokenCalls }
        }
    }

    var attemptRefreshCalls: Int {
        get async {
            lock.withLock { _attemptRefreshCalls }
        }
    }

    private func getAccessToken() -> String? {
        lock.withLock {
            _getAccessTokenCalls += 1
            return accessToken
        }
    }

    private func attemptRefresh() async -> Bool {
        lock.withLock {
            _attemptRefreshCalls += 1
        }

        if attemptRefreshDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: attemptRefreshDelayNanoseconds)
        }

        if refreshSucceeds, let refreshedAccessToken {
            lock.withLock {
                accessToken = refreshedAccessToken
            }
        }

        return refreshSucceeds
    }
}
