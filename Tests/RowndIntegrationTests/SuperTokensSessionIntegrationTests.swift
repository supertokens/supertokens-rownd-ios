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

    private func getJSON(path: String) async throws -> [String: Any] {
        let url = TestInfrastructure.backendURL.appendingPathComponent(path)
        let (data, response) = try await URLSession.shared.data(from: url)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(statusCode == 200)

        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
