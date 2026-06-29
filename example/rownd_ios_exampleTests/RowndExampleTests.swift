import XCTest
import AnyCodable
import SuperTokensIOS

@testable import Rownd

final class RowndExampleTests: XCTestCase {
    private let backendURL = URL(string: ProcessInfo.processInfo.environment["TEST_BACKEND_URL"] ?? "http://127.0.0.1:3100")!
    private let harnessSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        return URLSession(configuration: configuration)
    }()

    func testSuperTokensConfigDefaultsToAuthBasePath() {
        let config = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com"
        )

        XCTAssertEqual(config.appName, "Example App")
        XCTAssertEqual(config.apiDomain, "https://api.example.com")
        XCTAssertEqual(config.apiBasePath, "/auth")
    }

    func testExampleAppCanUseHarnessBackedSuperTokensSession() async throws {
        _ = try await request("POST", path: "/reset")
        let config = try await harnessConfig()

        Rownd.config.baseUrl = config.hubBaseUrl
        _ = await Rownd.configure(
            appKey: config.appKey,
            supertokens: RowndSuperTokensConfig(
                appName: "Rownd iOS Example E2E",
                apiDomain: config.supertokens.appInfo.apiDomain,
                apiBasePath: config.supertokens.appInfo.apiBasePath
            )
        )

        let accessToken = try await createSession(userId: "ios-example-e2e-user")
        XCTAssertFalse(accessToken.isEmpty)

        Rownd.user.set(data: [
            "user_id": AnyCodable("ios-example-e2e-user"),
            "email": AnyCodable("ios-example-e2e-user@example.com")
        ])

        try await updateProfile(accessToken: accessToken)
        try await signOut(accessToken: accessToken)
        await Rownd.signOut()

        let didSignOut = await waitForCounter("signOut", toEqual: 1, timeout: 10)
        XCTAssertTrue(didSignOut)

        let counters = try await json("GET", path: "/counters") as? [String: Any]
        XCTAssertGreaterThanOrEqual(counters?["createSession"] as? Int ?? 0, 1)
        XCTAssertGreaterThanOrEqual(counters?["userUpdate"] as? Int ?? 0, 1)
        XCTAssertEqual(counters?["legacyRefresh"] as? Int, 0)
    }

    private func harnessConfig() async throws -> E2EHarnessConfig {
        let data = try await request("GET", path: "/config")
        return try JSONDecoder().decode(E2EHarnessConfig.self, from: data)
    }

    private func createSession(userId: String) async throws -> String {
        let (_, response) = try await response("POST", path: "/test/session", body: ["userId": userId])
        let accessToken = try requiredHeader("st-access-token", in: response)
        let refreshToken = try requiredHeader("st-refresh-token", in: response)
        let frontToken = try requiredHeader("front-token", in: response)
        let antiCSRF = header("anti-csrf", in: response)

        await Task.detached {
            SuperTokensSessionBridge.bootstrapSession(
                accessToken: accessToken,
                refreshToken: refreshToken,
                frontToken: frontToken,
                antiCSRF: antiCSRF
            )
        }.value

        return accessToken
    }

    private func updateProfile(accessToken: String) async throws {
        _ = try await response("PUT", path: "/auth/plugin/rownd/user", body: [
            "data": [
                "user_id": "ios-example-e2e-user",
                "first_name": "E2E"
            ]
        ], session: harnessSession, headers: authorizationHeaders(accessToken))
    }

    private func signOut(accessToken: String) async throws {
        _ = try await response(
            "POST",
            path: "/auth/plugin/rownd/signout",
            session: harnessSession,
            headers: authorizationHeaders(accessToken)
        )
    }

    private func waitForCounter(_ name: String, toEqual expected: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let counters = try? await json("GET", path: "/counters") as? [String: Any],
               counters[name] as? Int == expected {
                return true
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return false
    }

    private func request(_ method: String, path: String, body: Any? = nil) async throws -> Data {
        let (data, _) = try await response(method, path: path, body: body)
        return data
    }

    private func response(_ method: String, path: String, body: Any? = nil) async throws -> (Data, HTTPURLResponse) {
        URLProtocol.unregisterClass(SuperTokensURLProtocol.self)
        defer { URLProtocol.registerClass(SuperTokensURLProtocol.self) }

        return try await response(method, path: path, body: body, session: harnessSession)
    }

    private func json(_ method: String, path: String, body: Any? = nil) async throws -> Any {
        let data = try await request(method, path: path, body: body)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func response(
        _ method: String,
        path: String,
        body: Any? = nil,
        session: URLSession,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: backendURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw E2ETestError.unexpectedResponse
        }

        return (data, response)
    }

    private func authorizationHeaders(_ accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "rid": "session",
            "fdi-version": "1.18",
            "st-auth-mode": "header"
        ]
    }

    private func requiredHeader(_ name: String, in response: HTTPURLResponse) throws -> String {
        guard let value = header(name, in: response) else {
            throw E2ETestError.missingHeader(name)
        }

        return value
    }

    private func header(_ name: String, in response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first { key, _ in
            (key as? String)?.lowercased() == name.lowercased()
        }?.value as? String
    }
}

private struct E2EHarnessConfig: Decodable {
    struct SuperTokens: Decodable {
        struct AppInfo: Decodable {
            let apiDomain: String
            let apiBasePath: String
        }

        let appInfo: AppInfo
    }

    let apiUrl: String
    let appKey: String
    let hubBaseUrl: String
    let supertokens: SuperTokens
}

private enum E2ETestError: Error {
    case unexpectedResponse
    case missingHeader(String)
}
