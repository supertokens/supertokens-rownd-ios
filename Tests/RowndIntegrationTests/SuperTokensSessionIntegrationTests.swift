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

    @Test func signOutAllCallsPluginSignoutAndClearsLocalSession() async throws {
        try await TestInfrastructure.prepare()

        try await createHarnessSession(userId: "ios-signout-all-user")
        #expect(await SuperTokensSessionBridge.doesSessionExist())

        try Rownd.signOut(scope: .all)

        for _ in 0..<40 {
            if await !SuperTokensSessionBridge.doesSessionExist() {
                break
            }

            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == nil)

        let counters = try await getJSON(path: "counters")
        #expect(counters["signOut"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)
    }

    @Test func hubStyleAuthenticationPayloadBootstrapsNativeSession() async throws {
        try await TestInfrastructure.prepare()

        let response = try await createHarnessSessionResponse(userId: "ios-hub-bootstrap-user", captureLocally: false)
        let accessToken = try #require(header(response, named: "st-access-token"))

        clearLocalSuperTokensSessionArtifacts()
        #expect(await !SuperTokensSessionBridge.doesSessionExist())

        await Task.detached(priority: .userInitiated) {
            SuperTokensSessionBridge.bootstrapSession(
                accessToken: accessToken,
                refreshToken: header(response, named: "st-refresh-token"),
                frontToken: header(response, named: "front-token"),
                antiCSRF: header(response, named: "anti-csrf")
            )
        }.value
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()

        #expect(await SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == "ios-hub-bootstrap-user")

        let counters = try await getJSON(path: "counters")
        #expect(counters["legacyRefresh"] as? Int == 0)
        #expect(counters["migrate"] as? Int == 0)
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
        let response = try await createHarnessSessionResponse(userId: userId, captureLocally: true)
        #expect(response.statusCode == 200)
    }

    private func createHarnessSessionResponse(userId: String, captureLocally: Bool) async throws -> HTTPURLResponse {
        var request = URLRequest(url: TestInfrastructure.backendURL.appendingPathComponent("test/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userId": userId])

        let session: URLSession
        if captureLocally {
            session = .shared
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = []
            session = URLSession(configuration: configuration)
        }

        let (data, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        let statusCode = httpResponse.statusCode
        #expect(statusCode == 200)

        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["status"] as? String == "OK")

        return httpResponse
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

    private func header(_ response: HTTPURLResponse, named name: String) -> String? {
        response.allHeaderFields.first { key, _ in
            (key as? String)?.caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }

    private func clearLocalSuperTokensSessionArtifacts() {
        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: "st-storage-item-st-access-token")
        userDefaults.removeObject(forKey: "st-storage-item-st-refresh-token")
        userDefaults.removeObject(forKey: "supertokens-ios-fronttoken-key")
        userDefaults.removeObject(forKey: "st-storage-item-st-last-access-token-update")
        userDefaults.removeObject(forKey: "supertokens-ios-anticsrf-key")
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
