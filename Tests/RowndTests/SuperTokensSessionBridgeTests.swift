import Foundation
import Testing

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

            await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == refreshToken)
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key") != nil)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-last-access-token-update") != nil)
        }
    }

    @Test func bootstrapSessionWithoutRefreshTokenDoesNotCreateSession() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)

            await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(accessToken: accessToken, refreshToken: nil)
            }.value

            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == nil)
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key") == nil)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-last-access-token-update") == nil)
        }
    }

    @Test func bootstrapSessionDoesNotPersistAntiCSRFWithoutRefreshToken() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)

            await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
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

            await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    frontToken: "front-token",
                    antiCSRF: "anti-csrf-token"
                )
            }.value

            #expect(SuperTokensSessionBridge.getRefreshToken() == refreshToken)
            #expect(SuperTokensSessionBridge.getFrontToken() == "front-token")
            #expect(SuperTokensSessionBridge.getAntiCSRF() == "anti-csrf-token")
        }
    }

    @Test func bootstrapSessionDoesNotOverwriteExistingSession() async throws {
        try await withMockedSuperTokensSession {
            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let replacementRefreshToken = makeSuperTokensTestJWT(expiresIn: 5400)

            await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value

            let originalFrontToken = UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key")

            await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: replacementRefreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.getAccessToken() == originalAccessToken)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == originalRefreshToken)
            #expect(UserDefaults.standard.string(forKey: "supertokens-ios-fronttoken-key") == originalFrontToken)
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
                SuperTokensSessionBridge.bootstrapSession(
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
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(UserDefaults.standard.string(forKey: "st-storage-item-st-refresh-token") == refreshToken)

            Rownd.signOut()

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
            URLProtocol.registerClass(SuperTokensSignOutURLProtocol.self)

            defer {
                URLProtocol.unregisterClass(SuperTokensSignOutURLProtocol.self)
            }

            await clearSessionIfNeeded()
            clearStoredSessionArtifacts()
            try await operation()
            await clearSessionIfNeeded()
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
        userDefaults.removeObject(forKey: "supertokens-ios-anticsrf-key")
    }

    private func makeSuperTokensTestJWT(expiresIn seconds: TimeInterval) -> String {
        // SuperTokens local session state reads real JWT claims such as sub and exp.
        generateJwt(expires: Date(timeIntervalSinceNow: seconds).timeIntervalSince1970)
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
