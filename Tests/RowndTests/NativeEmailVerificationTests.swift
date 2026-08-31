import Foundation
import AnyCodable
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
            status: "OK"
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

    @Test func verificationSessionTraversesSuperTokensURLProtocol() {
        let session = HubWebViewController.nativeEmailVerificationSession()
        #expect(session.configuration.protocolClasses?.first == SuperTokensURLProtocol.self)
    }

    @Test func verificationRequiresOKResponseStatus() async throws {
        let request = URLRequest(url: URL(string: "https://api.example.com/auth/user/email/verify")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmailVerificationResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let oldAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "old-session"
        )
        let newAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "new-session"
        )
        EmailVerificationResponseURLProtocol.responseBody = #"{"status":"OK"}"#.data(using: .utf8)!
        EmailVerificationResponseURLProtocol.replacementAccessToken = newAccessToken
        _ = try await HubWebViewController.performNativeEmailVerification(
            request: request,
            session: session,
            getAccessToken: accessTokenSequence(oldAccessToken, newAccessToken),
            getRefreshToken: { "new-refresh-token" },
            getFrontToken: { "new-front-token" },
            syncReplacementState: { expectedAccessToken, previousAccessToken in
                #expect(expectedAccessToken == newAccessToken)
                #expect(previousAccessToken == oldAccessToken)
                return .profileSynchronized
            }
        )

        EmailVerificationResponseURLProtocol.responseBody = #"{"status":"EMAIL_VERIFICATION_INVALID_TOKEN_ERROR"}"#.data(using: .utf8)!
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(request: request, session: session)
        }
    }

    @Test func verificationRejectsUnchangedOrMissingReplacementSession() async throws {
        let request = URLRequest(url: URL(string: "https://api.example.com/auth/user/email/verify")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmailVerificationResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        EmailVerificationResponseURLProtocol.responseBody = #"{"status":"OK"}"#.data(using: .utf8)!

        let sameAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "same-session"
        )
        let oldAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "old-session"
        )
        let newAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "new-session"
        )

        EmailVerificationResponseURLProtocol.replacementAccessToken = sameAccessToken
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence(sameAccessToken, sameAccessToken),
                getRefreshToken: { "refresh-token" },
                getFrontToken: { "front-token" },
                syncReplacementState: { _, _ in .profileSynchronized }
            )
        }
        EmailVerificationResponseURLProtocol.replacementAccessToken = newAccessToken
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence(oldAccessToken, nil),
                getRefreshToken: { "refresh-token" },
                getFrontToken: { "front-token" },
                syncReplacementState: { _, _ in .profileSynchronized }
            )
        }
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence(oldAccessToken, newAccessToken),
                getRefreshToken: { nil },
                getFrontToken: { "front-token" },
                syncReplacementState: { _, _ in .profileSynchronized }
            )
        }
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence(oldAccessToken, newAccessToken),
                getRefreshToken: { "refresh-token" },
                getFrontToken: { "" },
                syncReplacementState: { _, _ in .profileSynchronized }
            )
        }
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence(oldAccessToken, newAccessToken),
                getRefreshToken: { "refresh-token" },
                getFrontToken: { "front-token" },
                syncReplacementState: { _, _ in
                    throw RowndError("Replacement auth persistence failed")
                }
            )
        }
    }

    @Test func verificationStillCompletesWhenReplacementProfileIsUnavailable() async throws {
        let request = URLRequest(url: URL(string: "https://api.example.com/auth/user/email/verify")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmailVerificationResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let oldAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "old-session"
        )
        let newAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "new-session"
        )
        EmailVerificationResponseURLProtocol.responseBody = #"{"status":"OK"}"#.data(using: .utf8)!
        EmailVerificationResponseURLProtocol.replacementAccessToken = newAccessToken

        var scheduledIdentity: SuperTokensSessionBridge.StableSessionIdentity?
        let (_, response) = try await HubWebViewController.performNativeEmailVerification(
            request: request,
            session: session,
            getAccessToken: accessTokenSequence(oldAccessToken, newAccessToken),
            getRefreshToken: { "refresh-token" },
            getFrontToken: { "front-token" },
            syncReplacementState: { _, _ in .profileUnavailable },
            scheduleProfileRetry: { scheduledIdentity = $0 }
        )

        #expect(response.statusCode == 200)
        #expect(scheduledIdentity == SuperTokensSessionBridge.stableSessionIdentity(
            from: newAccessToken
        ))
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

            #expect(await waitForCondition {
                await MainActor.run {
                    store.state.user.data["email"]?.value as? String == "canonical@example.com"
                }
            })
            #expect(await responses.count == 2)
            #expect(await !coordinator.isScheduled(for: identity.stable))
            await MainActor.run {
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

    @Test func verificationAcceptsCurrentTokenRotationFromResponseSession() async throws {
        let request = URLRequest(url: URL(string: "https://api.example.com/auth/user/email/verify")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmailVerificationResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let oldAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "old-session"
        )
        let responseAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
            sessionHandle: "replacement-session"
        )
        let rotatedAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "replacement-session"
        )
        EmailVerificationResponseURLProtocol.responseBody = #"{"status":"OK"}"#.data(using: .utf8)!
        EmailVerificationResponseURLProtocol.replacementAccessToken = responseAccessToken

        _ = try await HubWebViewController.performNativeEmailVerification(
            request: request,
            session: session,
            getAccessToken: accessTokenSequence(oldAccessToken, rotatedAccessToken),
            getRefreshToken: { "refresh-token" },
            getFrontToken: { "front-token" },
            syncReplacementState: { expectedAccessToken, previousAccessToken in
                #expect(expectedAccessToken == responseAccessToken)
                #expect(previousAccessToken == oldAccessToken)
                return .profileSynchronized
            }
        )
    }

    @Test func verificationResponseCannotSynchronizeAConcurrentNewerSession() async throws {
        let request = URLRequest(url: URL(string: "https://api.example.com/auth/user/email/verify")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmailVerificationResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let oldAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "old-session"
        )
        let verificationAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "verification-session"
        )
        let newerAccessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "newer-session"
        )
        EmailVerificationResponseURLProtocol.responseBody = #"{"status":"OK"}"#.data(using: .utf8)!
        EmailVerificationResponseURLProtocol.replacementAccessToken = verificationAccessToken

        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence(oldAccessToken, newerAccessToken),
                getRefreshToken: { "newer-refresh-token" },
                getFrontToken: { "newer-front-token" },
                syncReplacementState: { _, _ in
                    Issue.record("A stale verification response must not synchronize newer auth")
                    return .profileSynchronized
                }
            )
        }
    }

    @Test func responseDeliveryRequiresUnchangedTrustedNavigation() throws {
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
    }

    @Test func sensitiveDeepLinkValuesAreRemovedFromLogUrls() throws {
        let url = try #require(URL(string:
            "https://hub.example.com/account/verify-email?token=email-token#rph_init=session-tokens"
        ))
        #expect(Redact.urlForLogging(url) == "https://hub.example.com/account/verify-email")
    }

    private func withNativeSessionHarness(
        _ operation: @escaping () async throws -> Void
    ) async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalInitialized = Rownd.isSuperTokensInitialized
            SuperTokens.resetForTests()
            Rownd.isSuperTokensInitialized = false
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Native verification tests",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )
            _ = try Rownd.initializeSuperTokensIfNeeded()
            let sessionStore = InMemorySessionStore()
            SDKStorage.setTokenStorageForTests(sessionStore)
            FrontToken.clearInMemoryCache()
            SuperTokensSessionBridge.storageOverride = sessionStore
            defer {
                SuperTokensSessionBridge.storageOverride = nil
                SuperTokens.resetForTests()
                Rownd.config = originalConfig
                Rownd.isSuperTokensInitialized = originalInitialized
            }
            try await operation()
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

private func accessTokenSequence(_ values: String?...) -> () async -> String? {
    var values = values
    return { values.removeFirst() }
}

private final class EmailVerificationResponseURLProtocol: URLProtocol {
    static var responseBody = Data()
    static var replacementAccessToken: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headerFields = ["Content-Type": "application/json"]
        headerFields["st-access-token"] = Self.replacementAccessToken
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headerFields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
