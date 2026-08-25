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

    // Every SuperTokens session artifact key, so setup/teardown can guarantee a
    // known-empty starting state. UserDefaults.standard persists on the simulator
    // across test processes, so without this a cold run inherits a prior run's
    // session and the first bootstrap sees a stale "session already exists".
    private static let allSessionKeys = [
        "st-storage-item-st-access-token",
        "st-storage-item-st-refresh-token",
        "supertokens-ios-fronttoken-key",
        "st-storage-item-st-last-access-token-update",
        "st-storage-item-sIRTFrontend",
        "supertokens-ios-anticsrf-key",
    ]

    // The single in-memory store that each harness installs as both the core
    // TokenStorage seam and the bridge storageOverride. Assertions read session
    // artifacts through this rather than UserDefaults.standard, which core purges
    // after every write.
    private static var activeStore = InMemorySessionStore()

    private static func resetToKnownState() {
        SuperTokensSessionBridge.storageOverride = nil
        SuperTokens.resetForTests()
        FrontToken.clearInMemoryCache()
        activeStore.reset()
        for key in allSessionKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // swift-testing instantiates the suite fresh per test, so init()/deinit act as
    // per-test setup/teardown: start and end each test from a guaranteed-clean state.
    init() {
        Self.resetToKnownState()
    }

    // Note: deinit for a value type isn't invoked by swift-testing the way a class
    // teardown would be, so each harness also cleans up on exit; resetToKnownState in
    // init() is the authoritative guarantee.

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
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == refreshToken)
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") != nil)
            #expect(Self.activeStore.get("st-storage-item-st-last-access-token-update") != nil)
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
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == nil)
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") == nil)
            #expect(Self.activeStore.get("st-storage-item-st-last-access-token-update") == nil)
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
            #expect(Self.activeStore.get("supertokens-ios-anticsrf-key") == nil)
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

            let originalFrontToken = Self.activeStore.get("supertokens-ios-fronttoken-key")

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
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == replacementRefreshToken)
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") != originalFrontToken)
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
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == refreshToken)
            #expect(Self.activeStore.get("supertokens-ios-anticsrf-key") == "original-anti-csrf")
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
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == refreshToken)

            await SuperTokensSessionBridge.signOut()

            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") == nil)
        }
    }

    @Test func signOutBetweenHubSessionAdoptionAndSyncWins() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
            }

            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value
            #expect(adopted)

            var steps: [String] = []
            let tokenWasRead = SessionSyncGate()
            let resumeSync = SessionSyncGate()
            let syncTask = Task {
                await HubWebViewController.completeAuthenticationAfterAdoption(
                    succeeded: adopted,
                    syncAuthState: {
                        steps.append("sync")
                        return await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                            afterTokenRead: {
                                await tokenWasRead.open()
                                await resumeSync.wait()
                            }
                        )
                    },
                    syncFailure: { steps.append("show-error") },
                    completion: { steps.append("complete") }
                )
            }

            await tokenWasRead.wait()
            await Rownd.signOut()
            await resumeSync.open()
            await syncTask.value

            #expect(steps == ["sync", "show-error"])
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
            await MainActor.run {
                #expect(Context.currentContext.store.state.auth.isAuthenticated == false)
            }
        }
    }

    @Test func refreshTokenChangeDuringSyncReconcilesRowndToRefreshedToken() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let refreshedAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: refreshToken
                )
            }.value
            #expect(adopted)

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {
                    let refreshed = await SuperTokensSessionBridge.attemptRefresh {
                        SDKStorage.set("st-storage-item-st-access-token", value: refreshedAccessToken)
                            && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                from: refreshedAccessToken
                            ))
                    }
                    #expect(refreshed)
                }
            )

            #expect(!synced)
            #expect(await MainActor.run { isolatedStore.state.auth.accessToken } == refreshedAccessToken)
        }
    }

    @Test func nonNilSessionReplacementAfterAuthDispatchReconcilesRownd() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let replacementRefreshToken = makeSuperTokensTestJWT(expiresIn: 5400)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            #expect(adopted)

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                afterAuthDispatch: {
                    let replaced = await Task.detached {
                        SuperTokensSessionBridge.bootstrapSession(
                            accessToken: replacementAccessToken,
                            refreshToken: replacementRefreshToken,
                            refreshSession: {
                                SDKStorage.set(
                                    "st-storage-item-st-access-token",
                                    value: replacementAccessToken
                                ) && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                    from: replacementAccessToken
                                ))
                            }
                        )
                    }.value
                    #expect(replaced)
                }
            )

            #expect(!synced)
            #expect(await MainActor.run { isolatedStore.state.auth.accessToken } == replacementAccessToken)
        }
    }

    @Test func replacementDuringReconciliationStabilizesOnLatestToken() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let firstReplacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let firstReplacementRefreshToken = makeSuperTokensTestJWT(expiresIn: 5400)
            let finalAccessToken = makeSuperTokensTestJWT(expiresIn: 900)
            let finalRefreshToken = makeSuperTokensTestJWT(expiresIn: 4500)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            #expect(adopted)

            func replaceSession(accessToken: String, refreshToken: String) async -> Bool {
                await Task.detached {
                    SuperTokensSessionBridge.bootstrapSession(
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        refreshSession: {
                            SDKStorage.set("st-storage-item-st-access-token", value: accessToken)
                                && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                    from: accessToken
                                ))
                        }
                    )
                }.value
            }

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                afterAuthDispatch: {
                    #expect(await replaceSession(
                        accessToken: firstReplacementAccessToken,
                        refreshToken: firstReplacementRefreshToken
                    ))
                },
                afterReconciliationDispatch: { attempt in
                    guard attempt == 0 else { return }
                    #expect(await replaceSession(
                        accessToken: finalAccessToken,
                        refreshToken: finalRefreshToken
                    ))
                }
            )

            #expect(!synced)
            #expect(await MainActor.run { isolatedStore.state.auth.accessToken } == finalAccessToken)
        }
    }

    @Test func reconciliationExhaustionClearsLastIntermediateToken() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let replacementTokens = [1800, 1500, 1200, 900].map {
                makeSuperTokensTestJWT(expiresIn: TimeInterval($0))
            }
            let replacementRefreshTokens = [5400, 5100, 4800, 4500].map {
                makeSuperTokensTestJWT(expiresIn: TimeInterval($0))
            }
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            #expect(adopted)

            func replaceSession(at index: Int) async -> Bool {
                let accessToken = replacementTokens[index]
                let refreshToken = replacementRefreshTokens[index]
                return await Task.detached {
                    SuperTokensSessionBridge.bootstrapSession(
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        refreshSession: {
                            SDKStorage.set("st-storage-item-st-access-token", value: accessToken)
                                && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                    from: accessToken
                                ))
                        }
                    )
                }.value
            }

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                afterAuthDispatch: {
                    #expect(await replaceSession(at: 0))
                },
                afterReconciliationDispatch: { attempt in
                    #expect(await replaceSession(at: attempt + 1))
                }
            )

            #expect(!synced)
            #expect(await SuperTokensSessionBridge.getAccessToken() == replacementTokens[3])
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == nil)
                #expect(!isolatedStore.state.auth.isAuthenticated)
            }
        }
    }

    @Test func localCleanupClearsSessionThroughCore() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    antiCSRF: "anti-csrf-token"
                )
            }.value
            #expect(await SuperTokensSessionBridge.doesSessionExist())

            #expect(SuperTokensSessionBridge.clearLocalSessionArtifacts())

            // The clear now routes through the core SDK (single source of truth);
            // verify the session is gone rather than asserting on hand-rolled keys.
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(SuperTokensSessionBridge.getFrontToken() == nil)
            #expect(SuperTokensSessionBridge.getAntiCSRF() == nil)
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
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == refreshToken)

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
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") == nil)
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
            // Force a clean SuperTokens init for every test. Another suite's harness
            // (withLocalSignOutServerSession) resets SuperTokens in its teardown while
            // leaving Rownd's isSuperTokensInitialized flag set, which would otherwise
            // make initializeSuperTokensIfNeeded short-circuit and leave
            // SuperTokens.isInitCalled false — breaking the core APIs the bridge now
            // routes through.
            let previousIsInitialized = Rownd.isSuperTokensInitialized
            SuperTokens.resetForTests()
            Rownd.isSuperTokensInitialized = false
            Rownd.config.supertokens = Self.supertokensConfig
            _ = try Rownd.initializeSuperTokensIfNeeded()
            let store = InMemorySessionStore()
            Self.activeStore = store
            SDKStorage.setTokenStorageForTests(store)
            let previousStorageOverride = SuperTokensSessionBridge.storageOverride
            SuperTokensSessionBridge.storageOverride = store
            URLProtocol.registerClass(SuperTokensSignOutURLProtocol.self)

            defer {
                URLProtocol.unregisterClass(SuperTokensSignOutURLProtocol.self)
                SuperTokensSessionBridge.storageOverride = previousStorageOverride
                SuperTokens.resetForTests()
                Rownd.isSuperTokensInitialized = previousIsInitialized
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
            let store = InMemorySessionStore()
            Self.activeStore = store
            SDKStorage.setTokenStorageForTests(store)
            let previousStorageOverride = SuperTokensSessionBridge.storageOverride
            SuperTokensSessionBridge.storageOverride = store

            defer {
                server.stop()
                SuperTokens.resetForTests()
                SuperTokensSessionBridge.storageOverride = previousStorageOverride
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
        Self.activeStore.reset()
        let userDefaults = UserDefaults.standard
        for key in Self.allSessionKeys {
            userDefaults.removeObject(forKey: key)
        }
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

private actor SessionSyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

// One in-memory store, shared by the core `TokenStorage` seam and the bridge's
// `SuperTokensSessionStorage`, so the core SDK reads/writes and the adopt-path's
// direct storage access stay on a single backing during tests.
//
// It must NOT be backed by UserDefaults.standard: core's `SDKStorage.set` writes to
// the token storage and then calls `UserDefaults.standard.removeObject(forKey:)` to
// purge the legacy-migration copy. A UserDefaults.standard-backed double is that same
// store, so every write would immediately erase itself and no session would ever be
// visible to a subsequent read. An in-memory dictionary sidesteps the legacy purge.
final class InMemorySessionStore: TokenStorage, SuperTokensSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    @discardableResult
    func set(_ key: String, value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        return true
    }

    @discardableResult
    func remove(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
        return true
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
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
