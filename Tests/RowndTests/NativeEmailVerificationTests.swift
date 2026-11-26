import Foundation
import AnyCodable
import ReSwift
@testable import SuperTokensIOS
import Testing

@testable import Rownd

@Suite(.serialized) struct NativeEmailVerificationTests {
    @Test @MainActor func emailVerificationCapabilityIsInjectedAtDocumentStart() {
        let controller = HubWebViewController()
        let capabilityScript = controller.webConfiguration.userContentController.userScripts.first(where: {
            $0.source.contains("__rowndNativeEmailVerificationBridge = true")
        })

        #expect(capabilityScript?.injectionTime == .atDocumentStart)
        #expect(capabilityScript?.isForMainFrameOnly == true)
    }

    @Test func verifyEmailMessageDecodesWithoutCredentials() throws {
        let message = try RowndHubInteropMessage.fromJson(
            message: #"{"type":"verify_email","payload":{"request_id":"request-123"}}"#
        )

        #expect(message.type == .verifyEmail)
        guard case .verifyEmail(let request) = message.payload else {
            Issue.record("Expected a verify-email payload")
            return
        }
        #expect(request.requestId == "request-123")
    }

    @Test func responseContainsOnlyCorrelationAndOutcome() throws {
        let script = try #require(HubWebViewController.nativeEmailVerificationEventScript(
            requestId: "request-123",
            expectedURL: URL(string: "https://hub.example.com/account/verify-email")!,
            outcome: .verified
        ))

        #expect(script.contains(HubWebViewController.nativeEmailVerificationEventName))
        #expect(script.contains(#""request_id":"request-123""#))
        #expect(script.contains(#""status":"OK""#))
        #expect(!script.contains("token"))
    }

    @Test func parametersRequireSingleTrustedNonEmptyValues() throws {
        let validURL = try #require(URL(string:
            "https://hub.example.com/account/verify-email?token=email-token&rowndPendingVerificationId=pending-123&apiDomain=https%3A%2F%2Fapi.example.com&apiBasePath=%2Fauth"
        ))
        let parameters = HubWebViewController.nativeEmailVerificationParameters(
            on: .deepLink,
            url: validURL,
            trustedApiDomain: "https://api.example.com",
            trustedApiBasePath: "/auth",
            baseURL: "https://hub.example.com"
        )

        #expect(parameters == .init(token: "email-token", pendingVerificationId: "pending-123"))

        let invalidURLs = [
            "https://hub.example.com/account/verify-email?token=&rowndPendingVerificationId=pending-123&apiDomain=https%3A%2F%2Fapi.example.com&apiBasePath=%2Fauth",
            "https://hub.example.com/account/verify-email?token=one&token=two&rowndPendingVerificationId=pending-123&apiDomain=https%3A%2F%2Fapi.example.com&apiBasePath=%2Fauth",
            "https://hub.example.com/account/verify-email?token=one&rowndPendingVerificationId=&apiDomain=https%3A%2F%2Fapi.example.com&apiBasePath=%2Fauth",
            "https://hub.example.com/account/verify-email?token=one&rowndPendingVerificationId=pending-123&apiDomain=https%3A%2F%2Fevil.example.com&apiBasePath=%2Fauth",
            "https://hub.example.com/account/verify-email?token=one&rowndPendingVerificationId=pending-123&apiDomain=https%3A%2F%2Fapi.example.com&apiBasePath=%2Fevil"
        ]

        for string in invalidURLs {
            #expect(HubWebViewController.nativeEmailVerificationParameters(
                on: .deepLink,
                url: URL(string: string),
                trustedApiDomain: "https://api.example.com",
                trustedApiBasePath: "/auth",
                baseURL: "https://hub.example.com"
            ) == nil)
        }
    }

    @Test func verificationRequestUsesConfiguredEndpointAndTokenBody() throws {
        let request = try HubWebViewController.nativeEmailVerificationRequest(
            parameters: .init(token: "email-token", pendingVerificationId: "pending / id"),
            apiDomain: "https://api.example.com",
            apiBasePath: "/auth"
        )

        #expect(request.url?.absoluteString == "https://api.example.com/auth/user/email/verify?rowndPendingVerificationId=pending%20/%20id")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["method": "token", "token": "email-token"])
    }

    @Test func verificationTransportRejectsRemoteHTTPAndAllowsLocalDevelopmentHTTP() throws {
        let parameters = HubWebViewController.NativeEmailVerificationParameters(
            token: "email-token",
            pendingVerificationId: "pending-123"
        )

        #expect(!HubWebViewController.isAllowedNativeEmailVerificationTransport("http://api.example.com"))
        #expect(HubWebViewController.isAllowedNativeEmailVerificationTransport("https://api.example.com"))

        for domain in ["http://localhost:3567", "http://127.0.0.1:3567", "http://[::1]:3567"] {
            #expect(HubWebViewController.isAllowedNativeEmailVerificationTransport(domain))
            let request = try HubWebViewController.nativeEmailVerificationRequest(
                parameters: parameters,
                apiDomain: domain,
                apiBasePath: "/auth"
            )
            #expect(request.url?.scheme == "http")
        }

        #expect(throws: (any Error).self) {
            try HubWebViewController.nativeEmailVerificationRequest(
                parameters: parameters,
                apiDomain: "http://api.example.com",
                apiBasePath: "/auth"
            )
        }
    }

    @Test func parameterAuthorizationRejectsConfiguredRemoteHTTPAndAllowsLocalHTTP() throws {
        func verificationURL(apiDomain: String) throws -> URL {
            var components = URLComponents(string: "https://hub.example.com/account/verify-email")!
            components.queryItems = [
                .init(name: "token", value: "email-token"),
                .init(name: "rowndPendingVerificationId", value: "pending-123"),
                .init(name: "apiDomain", value: apiDomain),
                .init(name: "apiBasePath", value: "/auth")
            ]
            return try #require(components.url)
        }

        #expect(HubWebViewController.nativeEmailVerificationParameters(
            on: .deepLink,
            url: try verificationURL(apiDomain: "http://api.example.com"),
            trustedApiDomain: "http://api.example.com",
            trustedApiBasePath: "/auth",
            baseURL: "https://hub.example.com"
        ) == nil)
        #expect(HubWebViewController.nativeEmailVerificationParameters(
            on: .deepLink,
            url: try verificationURL(apiDomain: "http://localhost:3567"),
            trustedApiDomain: "http://localhost:3567",
            trustedApiBasePath: "/auth",
            baseURL: "https://hub.example.com"
        ) != nil)
    }

    @Test func controllerOwnershipRequiresValidNativeRequestAndEndsOnNavigation() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }
            Rownd.config.baseUrl = "https://hub.example.com"
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Native verification tests",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )
            let validURL = try #require(URL(string:
                "https://hub.example.com/account/verify-email?token=email-token&rowndPendingVerificationId=pending-123&apiDomain=https%3A%2F%2Fapi.example.com&apiBasePath=%2Fauth"
            ))
            let invalidURL = try #require(URL(string:
                "https://hub.example.com/account/verify-email?token=email-token&apiDomain=https%3A%2F%2Fapi.example.com&apiBasePath=%2Fauth"
            ))

            await MainActor.run {
                let controller = HubWebViewController()
                let hub = NativeVerificationHubView()
                hub.targetPage = .deepLink
                controller.hubViewController = hub

                #expect(controller.claimNativeEmailVerificationOwnership(for: invalidURL) == nil)
                #expect(!controller.nativeEmailVerificationOwnsSessionReplacement)

                #expect(controller.claimNativeEmailVerificationOwnership(for: validURL) != nil)
                #expect(controller.nativeEmailVerificationOwnsSessionReplacement)

                // History replacement does not navigate, so URL cleanup must not release ownership.
                #expect(controller.nativeEmailVerificationOwnsSessionReplacement)

                controller.invalidateNativeEmailVerificationRequests()
                #expect(!controller.nativeEmailVerificationOwnsSessionReplacement)
            }
        }
    }

    @Test(arguments: NativeVerificationFailure.allCases)
    func replacementProfileFailuresRetainS1(_ failure: NativeVerificationFailure) async throws {
        try await withNativeSessionHarness {
            let originalContext = Context.currentContext
            let originalRequestSession = UserData.testingRequestSession
            let store = createStore()
            _ = Context(store)
            NativeVerificationFailureURLProtocol.failure = failure
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NativeVerificationFailureURLProtocol.self]
            UserData.testingRequestSession = URLSession(configuration: configuration)
            defer {
                UserData.testingRequestSession = originalRequestSession
                NativeVerificationFailureURLProtocol.failure = nil
                Context.currentContext = originalContext
            }

            let s0AccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "profile-failure-s0"
            )
            let s1AccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "profile-failure-s1"
            )
            await MainActor.run {
                store.dispatch(SetAuthState(payload: AuthState(accessToken: s0AccessToken)))
                store.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("stale-s0@example.com")
                ])))
            }
            _ = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: s1AccessToken,
                    refreshToken: "s1-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: s1AccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))

            let outcome = try await SuperTokensSessionBridge
                .syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: s1AccessToken,
                    expectedPreviousRowndAccessToken: s0AccessToken,
                    fetchUserData: { state in
                        switch try await UserData.fetchUserDataOnce(state) {
                        case .profile(let profile): return profile
                        case .notFound: return nil
                        }
                    },
                    persistState: { _ in true }
                )

            #expect(outcome == .profileUnavailable)
            #expect(await SuperTokensSessionBridge.getAccessToken() == s1AccessToken)
            await MainActor.run {
                #expect(store.state.auth.accessToken == s1AccessToken)
                #expect(
                    store.state.auth.profileHydrationPendingSessionIdentity
                        == SuperTokensSessionBridge.stableSessionIdentity(from: s1AccessToken)
                )
                #expect(store.state.user.data.isEmpty)
            }
        }
    }

    @Test func activeProfileHydrationRetryHydratesWhenProfileBecomesAvailable() async throws {
        try await withNativeSessionHarness {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }

            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "retry-hydration-session"
            )
            let identity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: accessToken,
                    refreshToken: "refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: accessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            await MainActor.run {
                var auth = AuthState(accessToken: accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                store.dispatch(SetAuthState(payload: auth))
            }
            let responses = ReplacementProfileResponseSequence()
            let coordinator = ProfileHydrationRetryCoordinator(
                delays: [0, 0, 0],
                sleep: { _ in }
            )

            await UserData.scheduleProfileHydrationRetry(
                for: identity.stable,
                coordinator: coordinator,
                appIsActive: { true },
                fetchUserData: { _ in await responses.next() },
                persistState: { _ in true }
            )

            await coordinator.waitForCurrentTaskToFinish()
            #expect(await responses.count == 2)
            #expect(await !coordinator.isScheduled(for: identity.stable))
            await MainActor.run {
                #expect(store.state.user.data["email"]?.value as? String == "canonical@example.com")
                #expect(store.state.auth.profileHydrationPendingSessionIdentity == nil)
            }
        }
    }

    @Test func profileHydrationRetryIgnoresSupersededSession() async throws {
        try await withNativeSessionHarness {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }

            let staleAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "stale-retry-session"
            )
            let replacementAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "replacement-retry-session"
            )
            let staleIdentity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: staleAccessToken,
                    refreshToken: "stale-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: staleAccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            await MainActor.run {
                var auth = AuthState(accessToken: staleAccessToken)
                auth.profileHydrationPendingSessionIdentity = staleIdentity.stable
                store.dispatch(SetAuthState(payload: auth))
            }
            let responses = ReplacementProfileResponseSequence()
            let coordinator = ProfileHydrationRetryCoordinator(
                delays: [20_000_000],
                sleep: { try await Task.sleep(nanoseconds: $0) }
            )
            await UserData.scheduleProfileHydrationRetry(
                for: staleIdentity.stable,
                coordinator: coordinator,
                appIsActive: { true },
                fetchUserData: { _ in await responses.next() },
                persistState: { _ in true }
            )

            #expect(await SuperTokensSessionBridge.adoptResponseSession(SuperTokensSessionTokens(
                accessToken: replacementAccessToken,
                refreshToken: "replacement-refresh-token",
                frontToken: SuperTokensSessionBridge.buildFrontToken(from: replacementAccessToken),
                antiCSRF: nil
            ), permit: SuperTokensSessionBridge.captureAuthOperationPermit()) != nil)
            await MainActor.run {
                store.dispatch(SetAuthState(payload: AuthState(accessToken: replacementAccessToken)))
                store.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("replacement@example.com")
                ])))
            }

            #expect(await waitForCondition {
                await !coordinator.isScheduled(for: staleIdentity.stable)
            })
            #expect(await responses.count == 0)
            await MainActor.run {
                #expect(store.state.auth.accessToken == replacementAccessToken)
                #expect(store.state.user.data["email"]?.value as? String == "replacement@example.com")
            }
        }
    }

    @Test func signOutCancelsPendingProfileHydrationRetry() async throws {
        try await withNativeSessionHarness {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }

            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "signout-retry-session"
            )
            let identity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: accessToken,
                    refreshToken: "refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: accessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            await MainActor.run {
                var auth = AuthState(accessToken: accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                store.dispatch(SetAuthState(payload: auth))
            }
            let responses = ReplacementProfileResponseSequence()
            let coordinator = UserData.profileHydrationRetryCoordinator
            await coordinator.cancel()
            await UserData.scheduleProfileHydrationRetry(
                for: identity.stable,
                appIsActive: { true },
                fetchUserData: { _ in await responses.next() },
                persistState: { _ in true }
            )
            #expect(await waitForCondition {
                await coordinator.isScheduled(for: identity.stable)
            })

            let wasInitialized = Rownd.isSuperTokensInitialized
            Rownd.isSuperTokensInitialized = false
            await Rownd.signOut()
            Rownd.isSuperTokensInitialized = wasInitialized

            #expect(await !coordinator.isScheduled(for: identity.stable))
            #expect(await responses.count == 0)
            await MainActor.run {
                #expect(!store.state.auth.isAuthenticated)
            }
        }
    }

    @Test func directCancellationInvalidatesBlockedRetryTicketWithoutCommitting() async throws {
        try await withNativeSessionHarness {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }

            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "direct-cancellation-retry-session"
            )
            let identity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: accessToken,
                    refreshToken: "refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: accessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            await MainActor.run {
                var auth = AuthState(accessToken: accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                store.dispatch(SetAuthState(payload: auth))
            }
            let response = BlockingProfileResponse()
            let coordinator = ProfileHydrationRetryCoordinator(
                delays: [0],
                sleep: { _ in }
            )
            await UserData.scheduleProfileHydrationRetry(
                for: identity.stable,
                coordinator: coordinator,
                appIsActive: { true },
                fetchUserData: { _ in await response.next() },
                persistState: { _ in true }
            )

            #expect(await waitForCondition { await response.hasStarted })
            let queueEntered = DispatchSemaphore(value: 0)
            let releaseQueue = DispatchSemaphore(value: 0)
            defer { releaseQueue.signal() }
            let queueBlocker = Task {
                await SuperTokensSessionBridge.attemptRefresh {
                    queueEntered.signal()
                    releaseQueue.wait()
                    return true
                }
            }
            await waitForSignal(queueEntered)
            await response.release()
            #expect(await waitForCondition { await response.hasFinished })

            await coordinator.cancel()
            let nextTicket = try #require(UserData.fetchCoordinator.begin(
                accessToken: accessToken,
                purpose: .foreground
            ))
            releaseQueue.signal()
            #expect(await queueBlocker.value)
            #expect(await waitForCondition {
                await MainActor.run { !store.state.user.isLoading }
            })

            await MainActor.run {
                #expect(
                    store.state.auth.profileHydrationPendingSessionIdentity
                        == identity.stable
                )
                #expect(store.state.user.data.isEmpty)
                #expect(!store.state.user.isLoading)
            }
            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(UserData.fetchCoordinator.isCurrent(nextTicket))
            UserData.fetchCoordinator.finish(nextTicket)
        }
    }

    @Test func profileHydrationRetryRemainsScheduledUntilAttemptReturns() async {
        let identity = SuperTokensSessionBridge.StableSessionIdentity(
            sessionHandle: "retry-completion-ordering",
            userId: "user-id",
            tenantId: nil
        )
        let resultPublished = NativeVerificationGate()
        let releaseAttempt = NativeVerificationGate()
        let coordinator = ProfileHydrationRetryCoordinator(
            delays: [0],
            sleep: { _ in }
        )

        await coordinator.schedule(for: identity) { _ in
            await resultPublished.open()
            await releaseAttempt.wait()
            return .stop
        }

        await resultPublished.wait()
        // An attempt can publish its result before returning to the coordinator.
        #expect(await coordinator.isScheduled(for: identity))
        await releaseAttempt.open()
        await coordinator.waitForCurrentTaskToFinish()
        #expect(await !coordinator.isScheduled(for: identity))
    }

    @Test func duplicateReplacementProfileRetrySchedulingIsIdempotent() async {
        let identity = SuperTokensSessionBridge.StableSessionIdentity(
            sessionHandle: "duplicate-retry-replacement",
            userId: "user-id",
            tenantId: nil
        )
        let sleepStarted = NativeVerificationGate()
        let releaseSleep = NativeVerificationGate()
        let attempts = NativeVerificationAttemptRecorder()
        let coordinator = ProfileHydrationRetryCoordinator(
            delays: [0],
            sleep: { _ in
                await sleepStarted.open()
                await releaseSleep.wait()
            }
        )

        await coordinator.schedule(for: identity) { _ in
            await attempts.record()
            return .stop
        }
        guard await waitForCondition(condition: { await sleepStarted.isOpen }) else {
            await releaseSleep.open()
            await coordinator.cancel()
            Issue.record("Replacement profile retry did not start")
            return
        }
        await coordinator.schedule(for: identity) { _ in
            Issue.record("Duplicate scheduling must not replace the active retry")
            return .stop
        }
        await releaseSleep.open()

        let finished = await waitForCondition {
            let attemptCount = await attempts.count
            let isScheduled = await coordinator.isScheduled(for: identity)
            return attemptCount == 1 && !isScheduled
        }
        if !finished {
            await coordinator.cancel()
        }
        #expect(finished)
    }

    @Test func case9StaleForegroundProfileSuccessCannotOverwriteReplacementIdentity() async throws {
        try await withNativeSessionHarness {
            UserData.fetchCoordinator.cancelCurrent()
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer {
                UserData.fetchCoordinator.cancelCurrent()
                Context.currentContext = originalContext
            }
            let s0AccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "case-9-s0"
            )
            let s1AccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "case-9-s1"
            )
            _ = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: s0AccessToken,
                    refreshToken: "s0-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: s0AccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            await MainActor.run {
                store.dispatch(SetAuthState(payload: AuthState(accessToken: s0AccessToken)))
                store.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("s0@example.com")
                ])))
            }
            let staleState = try #require(store.state)
            let staleFetchStarted = NativeVerificationGate()
            let releaseStaleFetch = NativeVerificationGate()
            let staleFetch = Task {
                await UserData.fetchForegroundUserData(
                    staleState,
                    fetchUserData: { _ in
                        await staleFetchStarted.open()
                        await releaseStaleFetch.wait()
                        return .profile(UserStateResponse(data: [
                            "email": AnyCodable("stale-s0@example.com")
                        ]))
                    },
                    persistState: { _ in true }
                )
            }
            guard await waitForCondition(condition: { await staleFetchStarted.isOpen }) else {
                await releaseStaleFetch.open()
                staleFetch.cancel()
                _ = await staleFetch.value
                Issue.record("Stale foreground profile fetch did not start")
                return
            }

            guard await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: s1AccessToken,
                    refreshToken: "s1-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: s1AccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ) != nil else {
                await releaseStaleFetch.open()
                staleFetch.cancel()
                _ = await staleFetch.value
                Issue.record("S1 could not be installed")
                return
            }
            let replacementOutcome: SuperTokensSessionBridge.ReplacementRowndStateSyncResult
            do {
                replacementOutcome = try await SuperTokensSessionBridge
                    .syncReplacementRowndStateFromSuperTokens(
                        expectedAccessToken: s1AccessToken,
                        expectedPreviousRowndAccessToken: s0AccessToken,
                        fetchUserData: { _ in
                            UserStateResponse(data: [
                                "email": AnyCodable("verified-s1@example.com")
                            ])
                        },
                        persistState: { _ in true }
                    )
            } catch {
                await releaseStaleFetch.open()
                staleFetch.cancel()
                _ = await staleFetch.value
                throw error
            }
            #expect(replacementOutcome == .profileSynchronized)
            await releaseStaleFetch.open()

            #expect(await staleFetch.value != .profileSynchronized)
            #expect(await SuperTokensSessionBridge.getAccessToken() == s1AccessToken)
            await MainActor.run {
                #expect(store.state.auth.accessToken == s1AccessToken)
                #expect(
                    store.state.user.data["email"]?.value as? String
                        == "verified-s1@example.com"
                )
            }
        }
    }

    @Test func backgroundThenForegroundKeepS1WhileBlockedReplacementFinishesStale() async throws {
        try await withNativeSessionHarness {
            UserData.fetchCoordinator.cancelCurrent()
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer {
                UserData.fetchCoordinator.cancelCurrent()
                Context.currentContext = originalContext
            }
            let s0AccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "lifecycle-s0"
            )
            let s1AccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "lifecycle-s1"
            )
            await MainActor.run {
                store.dispatch(SetAuthState(payload: AuthState(accessToken: s0AccessToken)))
                store.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("s0@example.com")
                ])))
            }
            _ = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: s1AccessToken,
                    refreshToken: "s1-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: s1AccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            let replacementFetchStarted = NativeVerificationGate()
            let releaseReplacementFetch = NativeVerificationGate()
            let replacementSync = Task {
                try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: s1AccessToken,
                    expectedPreviousRowndAccessToken: s0AccessToken,
                    fetchUserData: { _ in
                        await replacementFetchStarted.open()
                        await releaseReplacementFetch.wait()
                        return UserStateResponse(data: [
                            "email": AnyCodable("stale-replacement@example.com")
                        ])
                    },
                    persistState: { _ in true }
                )
            }
            guard await waitForCondition(condition: { await replacementFetchStarted.isOpen }) else {
                await releaseReplacementFetch.open()
                _ = try? await replacementSync.value
                Issue.record("Replacement profile fetch did not start")
                return
            }

            AppStateListener().appMovedToBackground()
            let foreground = NativeForegroundOutcomeRecorder()
            await Rownd.fetchInitialForegroundProfileIfNeeded(
                appIsActive: { true },
                fetchUserData: { state in
                    let outcome = await UserData.fetchForegroundUserData(
                        state,
                        fetchUserData: { _ in
                            .profile(UserStateResponse(data: [
                                "email": AnyCodable("canonical-s1@example.com")
                            ]))
                        },
                        persistState: { _ in true }
                    )
                    await foreground.record(outcome)
                    return outcome
                },
                scheduleRetry: { _ in }
            )
            await releaseReplacementFetch.open()

            await #expect(throws: (any Error).self) {
                try await replacementSync.value
            }
            #expect(await foreground.outcome == .profileSynchronized)
            #expect(await SuperTokensSessionBridge.getAccessToken() == s1AccessToken)
            await MainActor.run {
                #expect(store.state.auth.accessToken == s1AccessToken)
                #expect(
                    store.state.user.data["email"]?.value as? String
                        == "canonical-s1@example.com"
                )
            }
        }
    }

    @Test func nativeResponseDeliveryRejectsChangedGenerationURLOrTargetPage() throws {
        let url = try #require(URL(string: "https://hub.example.com/account/verify-email?token=secret"))

        #expect(HubWebViewController.canDeliverNativeEmailVerificationResponse(
            on: .deepLink,
            requestedURL: url,
            currentURL: url,
            requestedNavigationGeneration: 1,
            currentNavigationGeneration: 1,
            baseURL: "https://hub.example.com"
        ))
        #expect(!HubWebViewController.canDeliverNativeEmailVerificationResponse(
            on: .deepLink,
            requestedURL: url,
            currentURL: url,
            requestedNavigationGeneration: 1,
            currentNavigationGeneration: 2,
            baseURL: "https://hub.example.com"
        ))
        #expect(!HubWebViewController.canDeliverNativeEmailVerificationResponse(
            on: .deepLink,
            requestedURL: url,
            currentURL: URL(string: "https://hub.example.com/account"),
            requestedNavigationGeneration: 1,
            currentNavigationGeneration: 1,
            baseURL: "https://hub.example.com"
        ))
        #expect(!HubWebViewController.canDeliverNativeEmailVerificationResponse(
            on: .manageAccount,
            requestedURL: url,
            currentURL: url,
            requestedNavigationGeneration: 1,
            currentNavigationGeneration: 1,
            baseURL: "https://hub.example.com"
        ))
    }

    @Test func sensitiveDeepLinkValuesAreRemovedFromLogUrls() throws {
        let url = try #require(URL(string:
            "https://hub.example.com/account/verify-email?token=email-token#rph_init=session-tokens"
        ))
        #expect(Redact.urlForLogging(url) == "https://hub.example.com/account/verify-email")
    }

    @Test func verificationRequestAllowsSlowServerCommit() throws {
        let request = try HubWebViewController.nativeEmailVerificationRequest(
            parameters: .init(token: "email-token", pendingVerificationId: "pending-123"),
            apiDomain: "https://api.example.com",
            apiBasePath: "/auth"
        )
        #expect(request.timeoutInterval == 45)
    }

    @Test func verificationKeepsRunningWhenItsRequesterIsCancelled() async {
        let coordinator = NativeEmailVerificationCoordinator(beginBackgroundExecution: { {} })
        let started = NativeVerificationGate()
        let release = NativeVerificationGate()
        let finished = NativeVerificationGate()
        let key = verificationKey()
        let requester = Task {
            await coordinator.verify(key) {
                await started.open()
                await release.wait()
                #expect(!Task.isCancelled)
                await finished.open()
                return .verified
            }
        }
        guard await waitForCondition(condition: { await started.isOpen }) else {
            Issue.record("Verification did not start")
            await release.open()
            return
        }

        requester.cancel()
        await release.open()

        #expect(await waitForCondition(condition: { await finished.isOpen }))
        #expect(await requester.value == .verified)
    }

    @Test func concurrentRequestsForTheSameVerificationShareOneServerCall() async {
        let coordinator = NativeEmailVerificationCoordinator(beginBackgroundExecution: { {} })
        let attempts = NativeVerificationAttemptRecorder()
        let release = NativeVerificationGate()
        let key = verificationKey()
        let operation: @Sendable () async -> NativeEmailVerificationCoordinator.Outcome = {
            await attempts.record()
            await release.wait()
            return .failed(.signedOut)
        }

        let first = Task { await coordinator.verify(key, operation: operation) }
        guard await waitForCondition(condition: { await attempts.count == 1 }) else {
            Issue.record("Verification did not start")
            await release.open()
            return
        }
        let second = Task { await coordinator.verify(key, operation: operation) }
        let otherFlights = NativeVerificationAttemptRecorder()
        let otherOwner = Task {
            await coordinator.verify(verificationKey(owner: "other-session")) {
                await otherFlights.record()
                return .verified
            }
        }
        let otherEndpoint = Task {
            await coordinator.verify(verificationKey(domain: "http://127.0.0.1:1234")) {
                await otherFlights.record()
                return .verified
            }
        }
        #expect(await waitForCondition(condition: { await otherFlights.count == 2 }))
        await release.open()

        #expect(await otherOwner.value == .verified)
        #expect(await otherEndpoint.value == .verified)
        #expect(await first.value == .failed(.signedOut))
        #expect(await second.value == .failed(.signedOut))
        #expect(await attempts.count == 1)

        _ = await coordinator.verify(key, operation: operation)
        #expect(await attempts.count == 2)
    }

    @Test func verificationKeepsTheAppRunningUntilItFinishes() async {
        let coordinator = NativeEmailVerificationCoordinator(beginBackgroundExecution: {
            BackgroundExecutionRecorder.shared.begin()
            return { BackgroundExecutionRecorder.shared.end() }
        })
        BackgroundExecutionRecorder.shared.reset()
        let outcome = await coordinator.verify(verificationKey()) {
            #expect(BackgroundExecutionRecorder.shared.snapshot == (begun: 1, ended: 0))
            return .verified
        }
        #expect(outcome == .verified)
        #expect(BackgroundExecutionRecorder.shared.snapshot == (begun: 1, ended: 1))
    }

    @Test func verificationReusesOneURLSession() {
        #expect(
            HubWebViewController.nativeEmailVerificationSession()
                === HubWebViewController.nativeEmailVerificationSession()
        )
        #expect(HubWebViewController.nativeEmailVerificationSession().configuration.protocolClasses?
            .contains(where: { $0 == SuperTokensURLProtocol.self }) == false)
    }

    private static let verificationParameters = HubWebViewController.NativeEmailVerificationParameters(
        token: "email-token", pendingVerificationId: "pending-123"
    )

    private enum ReplacementResponse: CaseIterable {
        case verified, restored, unrelatedUser, unrelatedTenant
        case incompleteSuccess, incompleteError, installFailure
    }

    @Test(arguments: ReplacementResponse.allCases)
    private func verificationAdoptsOrRevokesOnlySameOwnerReplacements(_ scenario: ReplacementResponse) async throws {
        let s0 = Self.token("s0", tenantID: "tenant")
        let s1 = Self.token(
            "s1",
            userID: scenario == .unrelatedUser ? "other-user" : "user",
            tenantID: scenario == .unrelatedTenant ? "other-tenant" : "tenant"
        )
        let adopt = scenario == .verified || scenario == .restored
        let reportSuccess = scenario == .verified || scenario == .incompleteSuccess || scenario == .installFailure
        let revoke = scenario == .incompleteSuccess || scenario == .incompleteError || scenario == .installFailure
        var issuedResponse = Self.verificationResponse(
            replacement: s1,
            body: reportSuccess ? #"{"status":"OK"}"# : #"{"status":"GENERAL_ERROR"}"#
        )
        switch scenario {
        case .incompleteSuccess:
            issuedResponse.headers.removeValue(forKey: "St-Refresh-Token")
        case .incompleteError:
            issuedResponse.headers.removeValue(forKey: "Front-Token")
        case .installFailure:
            // Without `up`, the front token passes bridge identity checks but the SDK rejects it.
            let expiry = Int64(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)
            issuedResponse.headers["Front-Token"] = Data(#"{"uid":"user","ate":\#(expiry)}"#.utf8).base64EncodedString()
        default:
            break
        }
        let response = issuedResponse
        let profile = UserStateResponse(data: ["email": AnyCodable("current@example.com")])
        let profileBody = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        let server = try await LocalHTTPServer.start { request in
            switch request.path {
            case "/auth/plugin/rownd/user": return .init(headers: [:], body: profileBody)
            case "/auth/session/refresh": return .init(statusCode: adopt ? 401 : 200, headers: [:])
            case "/auth/signout": return .init()
            default: return response
            }
        }
        defer { server.stop() }
        try await withNativeSessionHarness(apiDomain: server.baseURL.absoluteString) {
            let (start, store) = try await self.captureVerification(s0, storeToken: s0)
            let outcome = await HubWebViewController.runNativeEmailVerification(
                parameters: Self.verificationParameters, start: start,
                syncReplacementState: { identity, start in
                    try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                        expectedAccessToken: identity.accessToken,
                        expectedPreviousRowndAccessToken: start.previousAccessToken,
                        persistState: { _ in true },
                        start: start,
                        installedIdentity: identity
                    )
                }
            )
            #expect(outcome == (scenario == .verified ? .verified : .failed(.sessionRetained)))
            let hubScript = try #require(HubWebViewController.nativeEmailVerificationEventScript(
                requestId: "request-123",
                expectedURL: server.baseURL.appendingPathComponent("account/verify-email"),
                outcome: outcome
            ))
            #expect(hubScript.contains(#""status":"OK""#) == (scenario == .verified))
            #expect(hubScript.contains(#""error":"Email verification failed""#) == (scenario != .verified))
            #expect(await SuperTokensSessionBridge.getAccessToken() == (adopt ? s1 : s0))
            #expect(SuperTokens.getRefreshToken() == (adopt ? "issued-refresh" : "refresh-s0"))
            if adopt {
                #expect(SuperTokens.getFrontToken() == response.headers["Front-Token"])
            }
            await MainActor.run {
                #expect(store.state.auth.isAuthenticated)
                #expect(store.state.auth.accessToken == (adopt ? s1 : s0))
                #expect(store.state.user.data["email"]?.value as? String == (adopt ? "current@example.com" : nil))
            }
            let verification = try await server.nextRequest()
            #expect(verification.path.hasPrefix("/auth/user/email/verify?"))
            #expect(verification.headers["authorization"] == "Bearer \(s0)")
            if revoke {
                let signOut = try await server.nextRequest()
                try #require(signOut.path == "/auth/signout")
                #expect(signOut.headers["authorization"] == "Bearer \(s1)")
                #expect(signOut.headers["anti-csrf"] == "issued-csrf")
            }
            let followUp = try await server.nextRequest()
            #expect(followUp.path == (adopt ? "/auth/plugin/rownd/user" : "/auth/session/refresh"))
            #expect(followUp.headers["authorization"] == (adopt ? "Bearer \(s1)" : "Bearer refresh-s0"))
            #expect(try await server.nextRequestIfAvailable() == nil)
        }
    }

    private enum Interruption: CaseIterable {
        case refresh401, signOut, signOutWithErrorResponse, signIn, signInThenSDKEmpty, hydrate, staleStore
    }

    @Test(arguments: Interruption.allCases)
    private func verificationUsesCapturedCredentialsAndAdoptsOrRevokesS1(_ interruption: Interruption) async throws {
        let s0 = Self.token("s0")
        let s1 = Self.token("s1")
        let b = Self.token("b", userID: "other-user")
        let verificationResponse = Self.verificationResponse(
            replacement: s1,
            body: interruption == .signOutWithErrorResponse ? #"{"status":"GENERAL_ERROR"}"# : #"{"status":"OK"}"#
        )
        let releaseVerification = NativeVerificationGate()
        let server = try await LocalHTTPServer.start { request in
            switch request.path {
            case "/auth/protected", "/auth/session/refresh": return .init(statusCode: 401, headers: [:])
            case "/auth/signout": return .init()
            default:
                await releaseVerification.wait()
                return verificationResponse
            }
        }
        defer { server.stop() }
        try await withNativeSessionHarness(apiDomain: server.baseURL.absoluteString) {
            let (start, store) = try await self.captureVerification(
                s0,
                storeToken: interruption == .hydrate ? nil : interruption == .staleStore ? Self.token("stale") : s0
            )
            let operation = Task {
                await HubWebViewController.runNativeEmailVerification(
                    parameters: Self.verificationParameters,
                    start: start,
                    syncReplacementState: { identity, start in
                        try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                            expectedAccessToken: identity.accessToken,
                            expectedPreviousRowndAccessToken: s0,
                            fetchUserData: { _ in UserStateResponse(data: ["email": AnyCodable("verified@example.com")]) },
                            persistState: { _ in true },
                            start: start,
                            installedIdentity: identity
                        )
                    }
                )
            }
            let adopt = [.refresh401, .hydrate, .staleStore].contains(interruption)
            do {
                let request = try await server.nextRequest()
                #expect(request.path == "/auth/user/email/verify?rowndPendingVerificationId=pending-123")
                #expect(request.headers["authorization"] == "Bearer \(s0)")
                #expect(request.headers["anti-csrf"] == "csrf-s0")
                #expect(request.headers["st-auth-mode"] == "header")
                #expect(request.headers["fdi-version"] == nil)

                switch interruption {
                case .refresh401:
                    // The globally registered interceptor's real refresh 401 advances
                    // the SDK generation before verification responds.
                    await #expect(throws: (any Error).self) {
                        try await URLSession.shared.data(from: server.baseURL.appendingPathComponent("auth/protected"))
                    }
                    let protected = try await server.nextRequest()
                    #expect(protected.path == "/auth/protected")
                    #expect(protected.headers["authorization"] == "Bearer \(s0)")
                    #expect(try await server.nextRequest().path == "/auth/session/refresh")
                    #expect(SuperTokens.getRefreshToken() == nil)
                    let reloadKey = await SuperTokensSessionBridge.emailVerificationJoinKey(
                        parameters: Self.verificationParameters, endpoint: start.endpoint
                    )
                    #expect(reloadKey == .init(
                        parameters: Self.verificationParameters, endpoint: start.endpoint,
                        owner: start.owner, ownership: start.ownership, storeID: start.storeID
                    ))
                case .signOut, .signOutWithErrorResponse:
                    SuperTokensSessionBridge.invalidateForSignOut()
                    _ = SuperTokensSessionBridge.clearLocalSessionArtifacts()
                    await MainActor.run { store.dispatch(SetAuthState(payload: AuthState())) }
                case .signIn:
                    try await self.signIn(b)
                    await MainActor.run {
                        store.dispatch(SetAuthState(payload: AuthState(accessToken: b)))
                        Rownd.config.supertokens.apiBasePath = "/wrong-api"
                    }
                case .signInThenSDKEmpty:
                    try await self.signIn(b)
                    _ = SuperTokensSessionBridge.clearLocalSessionArtifacts()
                case .hydrate:
                    await MainActor.run { store.dispatch(SetAuthState(payload: AuthState(accessToken: s0))) }
                case .staleStore:
                    break
                }
                await releaseVerification.open()
                #expect(await operation.value == (adopt ? .verified : .failed(.superseded)))
                if adopt {
                    #expect(SuperTokens.getRefreshToken() == "issued-refresh")
                    #expect(SuperTokens.getFrontToken() == verificationResponse.headers["Front-Token"])
                    #expect(SuperTokens.getAntiCSRF() == "issued-csrf")
                    #expect(await SuperTokensSessionBridge.getAccessToken() == s1)
                    #expect(await MainActor.run { store.state.auth.accessToken } == s1)
                    #expect(await MainActor.run { store.state.user.data["email"]?.value as? String } == "verified@example.com")
                } else {
                    let revoke = try await server.nextRequest()
                    #expect(revoke.path == "/auth/signout")
                    #expect(revoke.headers["authorization"] == "Bearer \(s1)")
                    #expect(revoke.headers["anti-csrf"] == "issued-csrf")
                    #expect(await SuperTokensSessionBridge.getAccessToken() == (interruption == .signIn ? b : nil))
                    if interruption == .signIn {
                        #expect(await MainActor.run { store.state.auth.accessToken } == b)
                    }
                }
            } catch {
                await releaseVerification.open()
                _ = await operation.value
                throw error
            }
        }
    }

    @Test func queuedVerificationCannotSendWithAnotherOwnersSession() async throws {
        let server = try await LocalHTTPServer.start()
        defer { server.stop() }
        try await withNativeSessionHarness(apiDomain: server.baseURL.absoluteString) {
            let (start, _) = try await self.captureVerification(Self.token("a"))
            try await self.signIn(Self.token("b"))
            let result = await HubWebViewController.runNativeEmailVerification(
                parameters: Self.verificationParameters, start: start
            )
            #expect(result == .failed(.superseded))
            #expect(try await server.nextRequestIfAvailable() == nil)
        }
    }

    @Test(arguments: [200, 307, 503])
    func revocationTransportRequires2xxAndNeverFollowsRedirects(_ status: Int) async throws {
        let server = try await LocalHTTPServer.start { _ in
            .init(statusCode: status, headers: ["Location": "/must-not-follow", "front-token": "remove"])
        }
        defer { server.stop() }
        try await withNativeSessionHarness(apiDomain: server.baseURL.absoluteString) {
            let active = Self.token("active")
            let issued = Self.token("issued")
            let (start, _) = try await self.captureVerification(active)
            #expect(await HubWebViewController.revokeIssuedSession(
                issuedAccessToken: issued, antiCSRF: nil, endpoint: start.endpoint
            ) == (status == 200))
            let request = try await server.nextRequest()
            #expect(request.path == "/auth/signout")
            #expect(request.headers["authorization"] == "Bearer \(issued)")
            #expect(request.headers["anti-csrf"] == nil)
            #expect(try await server.nextRequestIfAvailable() == nil)
            #expect(await SuperTokensSessionBridge.getAccessToken() == active)
        }
    }

    @Test(arguments: [401, 503, nil] as [Int?])
    func recoveryDistinguishesReal401FromTemporaryFailuresWithExpiredAccess(_ status: Int?) async throws {
        let server = try await LocalHTTPServer.start { _ in .init(statusCode: status ?? 503, headers: [:]) }
        defer { server.stop() }
        try await withNativeSessionHarness(apiDomain: server.baseURL.absoluteString) {
            let s0 = Self.token("expired", expiry: -60)
            let (start, store) = try await self.captureVerification(s0, storeToken: s0)
            #expect(start.previousAccessToken == s0)
            if status == nil { server.stop() }
            let outcome = await HubWebViewController.recoverFromFailedNativeEmailVerification(start: start)
            #expect(outcome == (status == 401 ? .signedOut : .unresolved))
            #expect(SuperTokens.getRefreshToken() == (status == 401 ? nil : "refresh-expired"))
            #expect(await MainActor.run { store.state.auth.accessToken } == (status == 401 ? nil : s0))
            if status != nil {
                let request = try await server.nextRequest()
                #expect(request.path == "/auth/session/refresh")
                #expect(request.headers["authorization"] == "Bearer refresh-expired")
                #expect(try await server.nextRequestIfAvailable() == nil)
            }
        }
    }

    @Test(arguments: [false, true])
    func revocationCleanupDoesNotClearSignInDuringMainActorHandoff(_ sdkCleared: Bool) async throws {
        try await withNativeSessionHarness {
            let a = Self.token("a")
            let (start, store) = try await self.captureVerification(a, storeToken: a)
            _ = SuperTokensSessionBridge.clearLocalSessionArtifacts()
            let b = Self.token("b")
            var didSignIn = false
            let cleared = await SuperTokensSessionBridge.clearRowndSessionRevokedOnServer(
                start,
                beforeCommit: {
                    do {
                        try await self.signIn(b)
                        didSignIn = true
                    } catch {
                        Issue.record("Could not install B's session: \(error)")
                    }
                    await MainActor.run { store.dispatch(SetAuthState(payload: AuthState(accessToken: b))) }
                    if sdkCleared { _ = SuperTokensSessionBridge.clearLocalSessionArtifacts() }
                },
                persistState: { _ in
                    Issue.record("Revocation cleanup persisted over the newly signed-in user")
                    return false
                }
            )
            #expect(!cleared)
            #expect(didSignIn)
            #expect(await MainActor.run { store.state.auth.accessToken } == b)
            #expect(await SuperTokensSessionBridge.getAccessToken() == (sdkCleared ? nil : b))
        }
    }

    @Test func replacementTokenRotationCannotWriteAfterSignOutStarts() async throws {
        try await withNativeSessionHarness {
            let s0 = Self.token("s0")
            let s1 = Self.token("s1")
            let rotated = Self.token("s1", expiry: 1800)
            let (start, store) = try await self.captureVerification(s0, storeToken: s0)
            guard case .installed(let installed) = await SuperTokensSessionBridge.installVerificationReplacement(
                accessToken: s1,
                refreshToken: "issued-refresh",
                frontToken: SuperTokensSessionBridge.buildFrontToken(from: s1),
                antiCSRF: nil,
                replacing: start
            ) else {
                Issue.record("S1 could not be installed")
                return
            }
            await #expect(throws: RowndError.self) {
                try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: s1,
                    expectedPreviousRowndAccessToken: s0,
                    fetchUserData: { _ in
                        SuperTokensSessionBridge.invalidateForSignOut()
                        #expect(SuperTokens.installSession(
                            accessToken: rotated,
                            refreshToken: "rotated-refresh",
                            frontToken: SuperTokensSessionBridge.buildFrontToken(from: rotated)
                        ))
                        return nil
                    },
                    persistState: { candidate in
                        #expect(candidate.auth.accessToken == s1)
                        return true
                    },
                    start: start,
                    installedIdentity: installed
                )
            }
            #expect(await MainActor.run { store.state.auth.accessToken } == s1)
        }
    }

    @Test(arguments: [200, 307, 503])
    func failedOrReplayedVerificationNeverInstallsOrFollowsRedirects(_ status: Int) async throws {
        let s0 = Self.token("s0")
        let server = try await LocalHTTPServer.start { request in
            if request.path == "/auth/session/refresh" { return .init(headers: [:]) }
            return .init(statusCode: status, headers: [
                "Location": "/must-not-follow",
                "St-Access-Token": s0,
                "St-Refresh-Token": "must-not-install",
                "Front-Token": SuperTokensSessionBridge.buildFrontToken(from: s0)
            ])
        }
        defer { server.stop() }
        try await withNativeSessionHarness(apiDomain: server.baseURL.absoluteString) {
            let (start, store) = try await self.captureVerification(s0, storeToken: s0)
            #expect(await HubWebViewController.runNativeEmailVerification(
                parameters: Self.verificationParameters, start: start,
                syncReplacementState: { _, _ in
                    Issue.record("A failed or replayed verification must not synchronize auth")
                    return .profileSynchronized
                }
            ) == .failed(.sessionRetained))
            #expect(try await server.nextRequest().path.hasPrefix("/auth/user/email/verify?"))
            #expect(try await server.nextRequest().path == "/auth/session/refresh")
            #expect(try await server.nextRequestIfAvailable() == nil)
            #expect(SuperTokens.getRefreshToken() == "refresh-s0")
            #expect(await MainActor.run { store.state.auth.accessToken } == s0)
        }
    }

    private static func token(
        _ handle: String, expiry: TimeInterval = 3600, userID: String = "user", tenantID: String? = nil
    ) -> String {
        generateJwt(
            expires: Date(timeIntervalSinceNow: expiry).timeIntervalSince1970,
            sessionHandle: handle, userId: userID, tenantId: tenantID
        )
    }

    private static func verificationResponse(
        replacement: String, body: String = #"{"status":"OK"}"#
    ) -> LocalHTTPServer.Response {
        .init(headers: [
            "St-Access-Token": replacement,
            "St-Refresh-Token": "issued-refresh",
            "Front-Token": SuperTokensSessionBridge.buildFrontToken(from: replacement),
            "Anti-Csrf": "issued-csrf"
        ], body: body)
    }

    private func signIn(_ accessToken: String) async throws {
        _ = try #require(await SuperTokensSessionBridge.adoptResponseSession(
            .init(accessToken: accessToken, refreshToken: "sign-in-refresh",
                  frontToken: SuperTokensSessionBridge.buildFrontToken(from: accessToken), antiCSRF: nil),
            permit: SuperTokensSessionBridge.captureAuthOperationPermit()
        ))
    }

    @MainActor private func captureVerification(
        _ accessToken: String,
        storeToken: String? = nil
    ) throws -> (NativeEmailVerificationStart, Store<RowndState>) {
        let owner = try #require(SuperTokensSessionBridge.stableSessionIdentity(from: accessToken))
        #expect(SuperTokens.installSession(
            accessToken: accessToken,
            refreshToken: "refresh-\(owner.sessionHandle)",
            frontToken: SuperTokensSessionBridge.buildFrontToken(from: accessToken),
            antiCSRFToken: "csrf-\(owner.sessionHandle)"
        ))
        let store = Context.currentContext.store
        store.dispatch(SetAuthState(payload: AuthState(accessToken: storeToken)))
        return (try #require(SuperTokensSessionBridge.captureEmailVerification(
            endpoint: .init(Rownd.config.supertokens)
        )), store)
    }

    private func verificationKey(
        owner: String = "initial-session",
        domain: String = "http://127.0.0.1"
    ) -> NativeEmailVerificationCoordinator.Key {
        .init(
            parameters: Self.verificationParameters,
            endpoint: .init(.init(appName: "test", apiDomain: domain, apiBasePath: "/auth")),
            owner: .init(sessionHandle: owner, userId: "user", tenantId: nil),
            ownership: SuperTokensSessionBridge.captureVerificationOwnership(),
            storeID: ObjectIdentifier(Self.self)
        )
    }

    private func withNativeSessionHarness(
        apiDomain: String = "https://api.example.com",
        _ operation: @escaping () async throws -> Void
    ) async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalContext = Context.currentContext
            _ = Context(createStore())
            let originalInitialized = Rownd.isSuperTokensInitialized
            await UserData.profileHydrationRetryCoordinator.cancel()
            UserData.fetchCoordinator.cancelCurrent()
            _ = await SuperTokensSessionBridge.getAccessToken()
            SuperTokens.resetForTests()
            Rownd.isSuperTokensInitialized = false
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Native verification tests",
                apiDomain: apiDomain,
                apiBasePath: "/auth"
            )
            _ = try Rownd.initializeSuperTokensIfNeeded()
            let sessionStore = InMemorySessionStore()
            SDKStorage.setTokenStorageForTests(sessionStore)
            FrontToken.clearInMemoryCache()
            SuperTokensSessionBridge.storageOverride = sessionStore
            let restore = {
                await UserData.profileHydrationRetryCoordinator.cancel()
                UserData.fetchCoordinator.cancelCurrent()
                _ = await SuperTokensSessionBridge.getAccessToken()
                SuperTokensSessionBridge.storageOverride = nil
                SuperTokens.resetForTests()
                Rownd.config = originalConfig
                Context.currentContext = originalContext
                Rownd.isSuperTokensInitialized = originalInitialized
            }
            do {
                try await operation()
                await restore()
            } catch {
                await restore()
                throw error
            }
        }
    }

    private func waitForCondition(
        attempts: Int = 100,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

}

private actor ReplacementProfileResponseSequence {
    private(set) var count = 0

    func next() -> UserData.FetchResult {
        count += 1
        if count == 1 {
            return .notFound
        }
        return .profile(UserStateResponse(data: [
            "email": AnyCodable("canonical@example.com")
        ]))
    }
}

@MainActor private final class NativeVerificationHubView: HubViewProtocol {
    var targetPage = HubPageSelector.unknown

    func setLoading(_ isLoading: Bool) {}
    func show() {}
    func hide() {}
    func hide(completion: (() -> Void)?) { completion?() }
    func updateBottomSheetHeight(_ height: CGFloat) {}
    func canTouchDimmingBackgroundToDismiss(_ enable: Bool) {}
}

private actor BlockingProfileResponse {
    private(set) var hasStarted = false
    private(set) var hasFinished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func next() async -> UserData.FetchResult {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        hasFinished = true
        return .profile(UserStateResponse(data: [
            "email": AnyCodable("must-not-commit@example.com")
        ]))
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor NativeVerificationGate {
    private(set) var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor NativeVerificationAttemptRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor NativeForegroundOutcomeRecorder {
    private(set) var outcome: UserData.ForegroundFetchOutcome?

    func record(_ outcome: UserData.ForegroundFetchOutcome) {
        self.outcome = outcome
    }
}

enum NativeVerificationFailure: CaseIterable {
    case unauthorized
    case notFound
    case serverError
    case serviceUnavailable
    case timedOut
    case offline
    case disconnected

    var statusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .notFound: return 404
        case .serverError: return 500
        case .serviceUnavailable: return 503
        case .timedOut, .offline, .disconnected: return nil
        }
    }

    var urlError: URLError? {
        switch self {
        case .timedOut: return URLError(.timedOut)
        case .offline: return URLError(.notConnectedToInternet)
        case .disconnected: return URLError(.networkConnectionLost)
        case .unauthorized, .notFound, .serverError, .serviceUnavailable: return nil
        }
    }
}

private final class NativeVerificationFailureURLProtocol: URLProtocol {
    static var failure: NativeVerificationFailure?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let failure = Self.failure else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        if let error = failure.urlError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: failure.statusCode!,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"ERROR"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BackgroundExecutionRecorder: @unchecked Sendable {
    static let shared = BackgroundExecutionRecorder()
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0

    var snapshot: (begun: Int, ended: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (begun, ended)
    }

    func reset() {
        lock.lock()
        begun = 0
        ended = 0
        lock.unlock()
    }

    func begin() {
        lock.lock()
        begun += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        ended += 1
        lock.unlock()
    }
}
