import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct SuperTokensSessionIntegrationTests {
    @Test func pluginAppConfigRouteIsServedBySuperTokensHarness() async throws {
        try await TestInfrastructure.prepare()

        let appConfig = try await getJSON(path: "auth/plugin/rownd/app-config")

        #expect(appConfig["status"] as? String == "OK")
        #expect(appConfig["id"] as? String == "app_test_rownd_ios")
        #expect(appConfig["name"] as? String == "Rownd iOS Integration Tests")
    }

    @Test func urlProtocolCapturesSessionHeadersFromSuperTokensResponse() async throws {
        try await TestInfrastructure.prepare()

        try await createHarnessSession(userId: "ios-session-capture-user")

        #expect(await SuperTokensSessionBridge.doesSessionExist())
        let accessToken = try #require(await SuperTokensSessionBridge.getAccessToken())
        #expect(!accessToken.isEmpty)
    }

    @Test func capturedSessionCanCallProtectedRouteAndSignOut() async throws {
        try await TestInfrastructure.prepare()

        try await createHarnessSession(userId: "ios-protected-user")

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == "ios-protected-user")

        await SuperTokensSessionBridge.signOut()

        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
    }

    @Test func validLegacySessionMigratesThroughHarness() async throws {
        try await TestInfrastructure.prepare()

        try await migrateLegacySession(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token"
        )

        #expect(await SuperTokensSessionBridge.doesSessionExist())

        let counters = try await getJSON(path: "counters")
        #expect(counters["migrate"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == "ios-test-user")
    }

    @Test func expiredLegacySessionRefreshesThenMigratesThroughHarness() async throws {
        try await TestInfrastructure.prepare()

        try await migrateLegacySession(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: -3600).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token"
        )

        #expect(await SuperTokensSessionBridge.doesSessionExist())

        let counters = try await getJSON(path: "counters")
        #expect(counters["migrate"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 1)
    }

    private func createHarnessSession(userId: String) async throws {
        var request = URLRequest(url: TestInfrastructure.backendURL.appendingPathComponent("test/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userId": userId])

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(statusCode == 200)

        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["status"] as? String == "OK")
    }

    private func migrateLegacySession(accessToken: String, refreshToken: String) async throws {
        await MainActor.run {
            Context.currentContext.store.dispatch(
                SetAuthState(payload: AuthState(accessToken: accessToken, refreshToken: refreshToken))
            )
        }

        await LegacySessionMigrator.migrateIfNeeded(
            authState: Context.currentContext.store.state.auth,
            dependencies: LegacySessionMigrationDependencies(
                client: LegacySessionMigrationClient(
                    apiDomain: TestInfrastructure.supertokensConfig.apiDomain,
                    apiBasePath: TestInfrastructure.supertokensConfig.apiBasePath,
                    legacyApiDomain: TestInfrastructure.supertokensConfig.apiDomain
                )
            )
        )
    }

    private func getJSON(path: String) async throws -> [String: Any] {
        let url = TestInfrastructure.backendURL.appendingPathComponent(path)
        let (data, response) = try await URLSession.shared.data(from: url)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(statusCode == 200)

        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func generateJwt(expires: TimeInterval) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let payload: [String: Any] = [
            "sub": "legacy-rownd-user",
            "exp": Int(expires),
        ]

        let headerData = try! JSONSerialization.data(withJSONObject: header)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)

        return [
            headerData.urlSafeBase64EncodedString(),
            payloadData.urlSafeBase64EncodedString(),
            "signature",
        ].joined(separator: ".")
    }
}

private extension Data {
    func urlSafeBase64EncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
