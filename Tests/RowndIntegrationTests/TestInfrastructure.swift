import Foundation
import Testing

@testable import Rownd

struct TestInfrastructure {
    static let backendURL = URL(
        string: ProcessInfo.processInfo.environment["TEST_BACKEND_URL"] ?? "http://127.0.0.1:3100"
    )!
    static let hubURL = URL(
        string: ProcessInfo.processInfo.environment["TEST_HUB_URL"] ?? "http://127.0.0.1:8787"
    )!

    static let supertokensConfig = RowndSuperTokensConfig(
        appName: "Rownd iOS Integration Tests",
        apiDomain: backendURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        apiBasePath: "/auth"
    )

    static func prepare() async throws {
        try await waitForBackend()
        try await waitForHub()
        try await resetBackend()

        Rownd.config.supertokens = supertokensConfig
        _ = try Rownd.initializeSuperTokensIfNeeded()

        if await SuperTokensSessionBridge.doesSessionExist() {
            await SuperTokensSessionBridge.signOut()
        }
    }

    static func waitForBackend(timeout: TimeInterval = 30) async throws {
        try await waitForHealth(url: backendURL.appendingPathComponent("health"), timeout: timeout)
    }

    static func waitForHub(timeout: TimeInterval = 30) async throws {
        try await waitForHealth(url: hubURL.appendingPathComponent("health"), timeout: timeout)
    }

    static func waitForHealth(url: URL, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return
            }

            try await Task.sleep(nanoseconds: 300_000_000)
        }

        throw RowndError("Timed out waiting for \(url.absoluteString)")
    }

    static func resetBackend() async throws {
        var request = URLRequest(url: backendURL.appendingPathComponent("reset"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(statusCode == 200)
    }
}
