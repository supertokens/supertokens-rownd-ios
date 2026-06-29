import Foundation
import Testing
@testable import SuperTokensIOS

@testable import SuperTokensRownd

struct TestInfrastructure {
    private static let sessionStorage = InMemorySuperTokensSessionStorage()

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
        sessionStorage.clear()
        SDKStorage.setTokenStorageForTests(sessionStorage)
        SuperTokensSessionBridge.storageOverride = sessionStorage

        if await SuperTokensSessionBridge.doesSessionExist() {
            await SuperTokensSessionBridge.signOut()
        }
        SuperTokensSessionBridge.clearLocalSessionArtifacts()
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

private final class InMemorySuperTokensSessionStorage: TokenStorage, SuperTokensSessionStorage {
    private var values: [String: String] = [:]

    func get(_ name: String) -> String? {
        values[name]
    }

    func set(_ name: String, value: String) -> Bool {
        values[name] = value
        return true
    }

    func remove(_ key: String) -> Bool {
        values.removeValue(forKey: key)
        return true
    }

    func clear() {
        values.removeAll()
    }
}
