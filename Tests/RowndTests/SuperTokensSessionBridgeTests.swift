import Foundation
import Testing
import Network
@testable import SuperTokensIOS

@testable import Rownd

@Suite(.serialized) struct SuperTokensSessionBridgeTests {
    private static let supertokensConfig = RowndSuperTokensConfig(
        appName: "Example App",
        apiDomain: "https://api.example.com",
        apiBasePath: "/auth"
    )

    @Test func bootstrapSessionCreatesVisibleSession() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(succeeded)
            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == refreshToken)
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key") != nil)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-last-access-token-update") != nil)
        }
    }

    @Test func bootstrapSessionWithoutRefreshTokenDoesNotCreateSession() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)

            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(accessToken: accessToken, refreshToken: nil)
            }.value

            #expect(!succeeded)
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == nil)
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key") == nil)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-last-access-token-update") == nil)
        }
    }

    @Test func bootstrapSessionRejectsMalformedTokens() async throws {
        try await withMockedSuperTokensSession {
            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: "not-a-jwt",
                    refreshToken: "refresh-token",
                    frontToken: "not-base64"
                )
            }.value

            #expect(!succeeded)
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
        }
    }

    @Test func bootstrapSessionDoesNotPersistAntiCSRFWithoutRefreshToken() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: nil,
                    antiCSRF: "anti-csrf-token"
                )
            }.value

            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-anticsrf-key") == nil)
        }
    }

    @Test func localArtifactGettersReturnPersistedSessionValues() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let frontToken = SuperTokensSessionBridge.buildFrontToken(from: accessToken)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    frontToken: frontToken,
                    antiCSRF: "anti-csrf-token"
                )
            }.value

            #expect(SuperTokensSessionBridge.getRefreshToken() == refreshToken)
            #expect(SuperTokensSessionBridge.getFrontToken() == frontToken)
            #expect(SuperTokensSessionBridge.getAntiCSRF() == "anti-csrf-token")
        }
    }

    @Test func bootstrapSessionReplacesExistingSession() async throws {
        try await withMockedSuperTokensSession {
            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let replacementRefreshToken = makeSuperTokensTestJWT(expiresIn: 5400)
            let replacementFrontToken = SuperTokensSessionBridge.buildFrontToken(from: replacementAccessToken)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value

            let originalFrontToken = UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key")

            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: replacementRefreshToken,
                    refreshSession: {
                        guard SDKStorage.set("st-storage-item-st-access-token", value: replacementAccessToken),
                              FrontToken.setItem(frontToken: replacementFrontToken) else {
                            return false
                        }
                        return true
                    }
                )
            }.value

            #expect(succeeded)
            #expect(await SuperTokensSessionBridge.getAccessToken() == replacementAccessToken)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == replacementRefreshToken)
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key") != originalFrontToken)
        }
    }

    @Test func bootstrapSessionCanRejectReplacingExistingSession() async throws {
        try await withMockedSuperTokensSession {
            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            let initialSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            let replacementSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: makeSuperTokensTestJWT(expiresIn: 1800),
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400),
                    allowReplacingExistingSession: false,
                    refreshSession: {
                        Issue.record("Replacement must not refresh the existing session")
                        return true
                    }
                )
            }.value

            #expect(initialSucceeded)
            #expect(!replacementSucceeded)
            #expect(await SuperTokensSessionBridge.getAccessToken() == originalAccessToken)
            #expect(SuperTokensSessionBridge.getRefreshToken() == originalRefreshToken)
        }
    }

    @Test func bootstrapSessionWithSameAccessTokenIsIdempotentSuccess() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            let firstSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    antiCSRF: "original-anti-csrf"
                )
            }.value
            let secondSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: "different-refresh-token",
                    antiCSRF: "different-anti-csrf"
                )
            }.value

            #expect(firstSucceeded)
            #expect(secondSucceeded)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == refreshToken)
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-anticsrf-key") == "original-anti-csrf")
        }
    }

    @Test func bootstrapSessionFailureRestoresExistingSession() async throws {
        try await withMockedSuperTokensSession {
            let storage = FailingSessionStorage()
            let previousStorage = SuperTokensSessionBridge.storageOverride
            SDKStorage.setTokenStorageForTests(storage)
            SuperTokensSessionBridge.storageOverride = storage
            defer {
                SuperTokensSessionBridge.storageOverride = previousStorage
            }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let initialSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            storage.failingKey = "st-storage-item-st-refresh-token"

            let replacementSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: makeSuperTokensTestJWT(expiresIn: 1800),
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value

            #expect(initialSucceeded)
            #expect(!replacementSucceeded)
            #expect(await SuperTokensSessionBridge.getAccessToken() == originalAccessToken)
            #expect(storage.get("st-storage-item-st-refresh-token") == originalRefreshToken)
        }
    }

    @Test func attemptRefreshReturnsFalseWhenNoSessionExists() async throws {
        try await withMockedSuperTokensSession {
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await !SuperTokensSessionBridge.attemptRefresh())
        }
    }

    @Test func bridgeMethodsCanBeCalledFromMainActorWithoutDeadlock() async throws {
        try await withMockedSuperTokensSession {
            try await expectCompletesWithinOneSecond {
                await callBlockingBridgeMethodsFromMainActor()
            }
        }
    }

    @Test func buildFrontTokenEncodesExpectedClaims() async throws {
        try await withGlobalTestLock {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let frontToken = SuperTokensSessionBridge.buildFrontToken(from: accessToken)
            let decodedData = try #require(Data(base64Encoded: frontToken))
            let decodedObject = try #require(
                try JSONSerialization.jsonObject(with: decodedData) as? [String: Any]
            )

            #expect(decodedObject["uid"] as? String == "1234567890")
            #expect((decodedObject["ate"] as? Int64 ?? 0) > 0)
            #expect(decodedObject["up"] as? [String: Any] != nil)
        }
    }

    @Test func bridgeSignOutClearsLocalSessionStateBeforeReturning() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == refreshToken)

            await SuperTokensSessionBridge.signOut()

            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key") == nil)
        }
    }

    @Test func localCleanupRemovesAllSuperTokensSessionArtifacts() async throws {
        try await withMockedSuperTokensSession {
            let storage = RecordingSessionStorage()
            let previousStorage = SuperTokensSessionBridge.storageOverride
            SuperTokensSessionBridge.storageOverride = storage
            defer {
                SuperTokensSessionBridge.storageOverride = previousStorage
            }

            let keys = [
                "st-storage-item-st-access-token",
                "st-storage-item-st-refresh-token",
                "supertokens-ios-fronttoken-key",
                "st-storage-item-st-last-access-token-update",
                "st-storage-item-sIRTFrontend",
                "supertokens-ios-anticsrf-key"
            ]
            for key in keys {
                UserDefaults.standard.set("value", forKey: key)
            }

            #expect(SuperTokensSessionBridge.clearLocalSessionArtifacts())

            for key in keys {
                #expect(UserDefaults.standard.string(forKey: key) == nil)
            }
            #expect(Set(storage.removedKeys) == Set(keys))
        }
    }

    @Test func rowndSignOutClearsSuperTokensAndCompatibilityState() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
            }

            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            await MainActor.run {
                Context.currentContext.store.dispatch(
                    SetAuthState(
                        payload: AuthState(accessToken: accessToken, refreshToken: refreshToken)
                    )
                )
            }

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == refreshToken)

            await Rownd.signOut()

            for _ in 0..<40 {
                let isAuthenticated = await MainActor.run {
                    Context.currentContext.store.state?.auth.isAuthenticated
                }

                if isAuthenticated == false, await !SuperTokensSessionBridge.doesSessionExist() {
                    break
                }

                try await Task.sleep(nanoseconds: 25_000_000)
            }

            await MainActor.run {
                #expect(Context.currentContext.store.state?.auth.isAuthenticated == false)
            }
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key") == nil)
        }
    }

    @Test func rowndSignOutAsyncKeepsAuthorizationWhenCallerClearsStorageAfterReturn() async throws {
        try await withLocalSignOutServerSession { server in
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.doesSessionExist())

            await Rownd.signOut()
            clearStoredSessionArtifacts()

            let request = try await server.nextRequest()
            #expect(request.path == "/auth/signout")
            #expect(request.headers["authorization"]?.hasPrefix("Bearer ") == true)
        }
    }

    @Test func rowndSignOutFireAndForgetCanLoseAuthorizationWhenCallerClearsStorageImmediately() async throws {
        try await withLocalSignOutServerSession { server in
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.doesSessionExist())

            callFireAndForgetSignOut()
            clearStoredSessionArtifacts()

            let request = try await server.nextRequestIfAvailable()
            if let request {
                #expect(request.path == "/auth/signout")
                #expect(request.headers["authorization"]?.hasPrefix("Bearer ") != true)
            }
        }
    }

    @Test func blockingSuperTokensApisAreOnlyUsedThroughBridge() async throws {
        try await withGlobalTestLock {
            let sourceRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Rownd")

            let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )

            var directReferences: [String] = []

            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                let contents = try String(contentsOf: fileURL)

                if contents.contains("SuperTokens.doesSessionExist(")
                    || contents.contains("SuperTokens.attemptRefreshingSession(")
                {
                    directReferences.append(fileURL.lastPathComponent)
                }
            }

            #expect(directReferences == ["SuperTokensSessionBridge.swift"])
        }
    }

    private func withMockedSuperTokensSession(
        _ operation: @escaping () async throws -> Void
    ) async throws {
        try await withGlobalTestLock {
            Rownd.config.supertokens = Self.supertokensConfig
            _ = try Rownd.initializeSuperTokensIfNeeded()
            SDKStorage.setTokenStorageForTests(UserDefaultsTokenStorage())
            URLProtocol.registerClass(SuperTokensSignOutURLProtocol.self)

            defer {
                URLProtocol.unregisterClass(SuperTokensSignOutURLProtocol.self)
            }

            clearStoredSessionArtifacts()
            await clearSessionIfNeeded()
            try await operation()
            await clearSessionIfNeeded()
            clearStoredSessionArtifacts()
        }
    }

    private func withLocalSignOutServerSession(
        _ operation: @escaping (LocalHTTPServer) async throws -> Void
    ) async throws {
        try await withGlobalTestLock {
            let server = try await LocalHTTPServer.start()
            let originalSuperTokensConfig = Rownd.config.supertokens
            let originalIsSuperTokensInitialized = Rownd.isSuperTokensInitialized

            Rownd.isSuperTokensInitialized = false
            SuperTokens.resetForTests()
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Signout Race Test",
                apiDomain: server.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                apiBasePath: "/auth"
            )
            _ = try Rownd.initializeSuperTokensIfNeeded()
            SDKStorage.setTokenStorageForTests(UserDefaultsTokenStorage())

            defer {
                server.stop()
                SuperTokens.resetForTests()
                Rownd.config.supertokens = originalSuperTokensConfig
                Rownd.isSuperTokensInitialized = originalIsSuperTokensInitialized
            }

            clearStoredSessionArtifacts()
            try await operation(server)
            clearStoredSessionArtifacts()
        }
    }

    private func clearSessionIfNeeded() async {
        if await SuperTokensSessionBridge.doesSessionExist() {
            await SuperTokensSessionBridge.signOut()
        }
    }

    private func clearStoredSessionArtifacts() {
        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: "st-storage-item-st-access-token")
        userDefaults.removeObject(forKey: "st-storage-item-st-refresh-token")
        userDefaults.removeObject(forKey: "supertokens-ios-fronttoken-key")
        userDefaults.removeObject(forKey: "st-storage-item-st-last-access-token-update")
        userDefaults.removeObject(forKey: "st-storage-item-sIRTFrontend")
        userDefaults.removeObject(forKey: "supertokens-ios-anticsrf-key")
    }

    private func callFireAndForgetSignOut() {
        Rownd.signOut()
    }

    private func makeSuperTokensTestJWT(expiresIn seconds: TimeInterval) -> String {
        // SuperTokens local session state reads real JWT claims such as sub and exp.
        generateJwt(
            expires: Date(timeIntervalSinceNow: seconds).timeIntervalSince1970,
            sessionHandle: "test-session"
        )
    }

    @MainActor private func callBlockingBridgeMethodsFromMainActor() async {
        _ = await SuperTokensSessionBridge.doesSessionExist()
        _ = await SuperTokensSessionBridge.attemptRefresh()
    }

    private func expectCompletesWithinOneSecond(
        _ operation: @escaping @Sendable () async -> Void
    ) async throws {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }

            let completed = await group.next() ?? false
            group.cancelAll()
            #expect(completed)
        }
    }
}

private final class UserDefaultsTokenStorage: TokenStorage {
    func get(_ name: String) -> String? {
        UserDefaults.standard.string(forKey: name)
    }

    func set(_ name: String, value: String) -> Bool {
        UserDefaults.standard.set(value, forKey: name)
        return true
    }

    func remove(_ name: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: name)
        return true
    }
}

private final class RecordingSessionStorage: SuperTokensSessionStorage {
    private(set) var removedKeys: [String] = []

    func get(_ key: String) -> String? {
        nil
    }

    func set(_ key: String, value: String) -> Bool {
        true
    }

    func remove(_ key: String) -> Bool {
        removedKeys.append(key)
        return true
    }
}

private final class FailingSessionStorage: TokenStorage, SuperTokensSessionStorage {
    var failingKey: String?
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? {
        values[key]
    }

    func set(_ key: String, value: String) -> Bool {
        guard key != failingKey else { return false }
        values[key] = value
        return true
    }

    func remove(_ key: String) -> Bool {
        values.removeValue(forKey: key)
        return true
    }
}

private final class SuperTokensSignOutURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString == "https://api.example.com/auth/signout"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "front-token": "remove",
            ]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"OK"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LocalHTTPServer: @unchecked Sendable {
    struct CapturedRequest: Sendable {
        var path: String
        var headers: [String: String]
    }

    private(set) var baseURL: URL!

    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.rownd.tests.local-http-server")
    private let requests: AsyncStream<CapturedRequest>
    private let requestContinuation: AsyncStream<CapturedRequest>.Continuation

    private init(listener: NWListener) {
        self.listener = listener

        var continuation: AsyncStream<CapturedRequest>.Continuation!
        self.requests = AsyncStream { continuation = $0 }
        self.requestContinuation = continuation
    }

    static func start() async throws -> LocalHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = LocalHTTPServer(listener: listener)

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false

            listener.newConnectionHandler = { connection in
                server.handle(connection)
            }

            listener.stateUpdateHandler = { state in
                guard !hasResumed else { return }

                switch state {
                case .ready:
                    guard let port = listener.port else {
                        hasResumed = true
                        continuation.resume(throwing: RowndError("Local test server started without a port"))
                        return
                    }

                    server.baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)")!
                    hasResumed = true
                    continuation.resume(returning: server)
                case .failed(let error):
                    hasResumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.start(queue: DispatchQueue(label: "io.rownd.tests.local-http-listener"))
        }
    }

    func stop() {
        listener.cancel()
        requestContinuation.finish()
    }

    func nextRequest(timeout: TimeInterval = 2) async throws -> CapturedRequest {
        try await withThrowingTaskGroup(of: CapturedRequest.self) { group in
            group.addTask { [requests] in
                for await request in requests {
                    return request
                }
                throw RowndError("Local test server stopped before receiving a request")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RowndError("Timed out waiting for local test server request")
            }

            let request = try await group.next()!
            group.cancelAll()
            return request
        }
    }

    func nextRequestIfAvailable(timeout: TimeInterval = 0.5) async throws -> CapturedRequest? {
        try await withThrowingTaskGroup(of: CapturedRequest?.self) { group in
            group.addTask { [requests] in
                for await request in requests {
                    return request
                }
                throw RowndError("Local test server stopped before receiving a request")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            let request = try await group.next()!
            group.cancelAll()
            return request
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            guard String(data: nextBuffer, encoding: .utf8)?.contains("\r\n\r\n") == true else {
                self.receive(on: connection, buffer: nextBuffer)
                return
            }

            self.requestContinuation.yield(Self.parseRequest(nextBuffer))
            self.sendResponse(on: connection)
        }
    }

    private func sendResponse(on connection: NWConnection) {
        let body = #"{"status":"OK"}"#
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            front-token: remove\r
            Connection: close\r
            \r
            \(body)
            """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(_ data: Data) -> CapturedRequest {
        let rawRequest = String(data: data, encoding: .utf8) ?? ""
        let lines = rawRequest.components(separatedBy: "\r\n")
        let requestLineParts = (lines.first ?? "").split(separator: " ")
        var headers: [String: String] = [:]

        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return CapturedRequest(
            path: requestLineParts.count > 1 ? String(requestLineParts[1]) : "",
            headers: headers
        )
    }
}
