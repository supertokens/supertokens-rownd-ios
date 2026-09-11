import Foundation
import JWTDecode
import Testing

@testable import Rownd

extension SuperTokensSessionIntegrationTests {
    @Test func expiredAccessTokenRefreshesOnStartupWithoutSigningInAgain() async throws {
        let fixture = try await prepareExpiringSession()

        #expect(await Rownd.reconcileStartupSession())
        let token = try #require(try await Rownd.getAccessToken(throwIfMissing: true))
        #expect(token != fixture.accessToken)
        #expect(SuperTokensSessionBridge.getRefreshToken() != fixture.refreshToken)
        #expect(SuperTokensSessionBridge.stableSessionIdentity(from: token)?.sessionHandle == fixture.sessionHandle)
        let jwt = try decode(jwt: token)
        #expect(try #require(jwt.expiresAt).timeIntervalSinceNow > 3300)
        try await assertProtectedSession(userId: fixture.userId)

        let counters = try await controlRequest("GET", path: "counters")
        #expect(counters["stRefresh"] as? Int == 1)
        #expect(counters["createSession"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)
    }

    @Test(arguments: [true, false])
    func temporaryRefreshOutageDoesNotClearPersistedLoginOnStartup(waitForExpiry: Bool) async throws {
        let fixture = try await prepareExpiringSession(waitForExpiry: waitForExpiry)
        _ = try await controlRequest("POST", path: "test/refresh-availability", body: ["unavailable": true])

        await #expect(throws: AuthenticationError.serverError(
            details: waitForExpiry
                ? "Session refresh failed temporarily; retry when the service is available"
                : "Session refresh did not produce a usable access token"
        )) {
            _ = try await Rownd.getAccessToken()
        }
        _ = await Rownd.reconcileStartupSession()

        // A 503 cannot establish that the session was revoked. Core credentials
        // and the cached Rownd identity must survive until refresh can be retried.
        #expect(SuperTokensSessionBridge.getRefreshToken() == fixture.refreshToken)
        await MainActor.run {
            #expect(Context.currentContext.store.state.auth.accessToken == fixture.accessToken)
            #expect(Context.currentContext.store.state.auth.isAuthenticated)
        }
        let savedJSON = try #require(Storage.shared.get(forKey: "RowndState"))
        let savedState = try JSONDecoder().decode(RowndState.self, from: Data(savedJSON.utf8))
        #expect(savedState.auth.isAuthenticated)

        _ = try await controlRequest("POST", path: "test/refresh-availability", body: ["unavailable": false])
        #expect(await Rownd.reconcileStartupSession())
        try await assertProtectedSession(userId: fixture.userId)
        let counters = try await controlRequest("GET", path: "counters")
        #expect(counters["createSession"] as? Int == 1)
    }

    @Test func revokedSessionClearsPersistedLoginOnStartup() async throws {
        let fixture = try await prepareExpiringSession()
        _ = try await controlRequest("POST", path: "test/revoke-session", body: ["sessionHandle": fixture.sessionHandle])

        _ = await Rownd.reconcileStartupSession()

        #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
        #expect(try await Rownd.getAccessToken() == nil)
        await MainActor.run {
            #expect(!Context.currentContext.store.state.auth.isAuthenticated)
        }
        let counters = try await controlRequest("GET", path: "counters")
        #expect(counters["stRefresh"] as? Int == 1)
    }

    private struct SessionFixture {
        let userId: String
        let sessionHandle: String
        let accessToken: String
        let refreshToken: String
    }

    private func prepareExpiringSession(waitForExpiry: Bool = true) async throws -> SessionFixture {
        try await TestInfrastructure.prepare()
        var request = URLRequest(url: TestInfrastructure.backendURL.appendingPathComponent("test/expiring-session"))
        request.httpMethod = "POST"
        request.setValue("header", forHTTPHeaderField: "st-auth-mode")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "accessTokenValidity": waitForExpiry ? 5 : 30
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        try #require(httpResponse.statusCode == 200)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accessToken = try #require(httpResponse.value(forHTTPHeaderField: "st-access-token"))
        let refreshToken = try #require(httpResponse.value(forHTTPHeaderField: "st-refresh-token"))
        let info = try #require(body["info"] as? [String: Any])
        let expiry = try #require(info["expiry"] as? Double)
        let created = try #require(info["timeCreated"] as? Double)
        #expect(abs((expiry - created) / 1000 - 144000 * 60) < 5)

        await MainActor.run {
            let store = Context.currentContext.store
            store.dispatch(SetAuthState(payload: AuthState(accessToken: accessToken)))
            #expect(store.state.saveImmediately())
        }
        let expiresAt = try #require(try decode(jwt: accessToken).expiresAt)
        try #require(expiresAt.timeIntervalSinceNow < (waitForExpiry ? 10 : 35))
        if waitForExpiry {
            let delay = max(0, expiresAt.timeIntervalSinceNow) + 1
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return SessionFixture(
            userId: try #require(body["userId"] as? String),
            sessionHandle: try #require(body["sessionHandle"] as? String),
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    private func assertProtectedSession(userId: String) async throws {
        _ = try #require(try await Rownd.getAccessToken(throwIfMissing: true))
        let (data, response) = try await URLSession.shared.data(
            from: TestInfrastructure.backendURL.appendingPathComponent("test/protected")
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["userId"] as? String == userId)
        await MainActor.run {
            #expect(Context.currentContext.store.state.auth.isAuthenticated)
        }
    }

    private func controlRequest(
        _ method: String,
        path: String,
        body: [String: Any] = [:]
    ) async throws -> [String: Any] {
        // Test controls must not trigger the SDK interceptor's automatic refresh.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: TestInfrastructure.backendURL.appendingPathComponent(path))
        request.httpMethod = method
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
