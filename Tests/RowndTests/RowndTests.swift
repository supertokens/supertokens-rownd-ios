//
//  RowndTests.swift
//  RowndTests
//
//  Created by Matt Hamann on 7/15/22.
//

import Testing
@testable import SuperTokensRownd
import Foundation
import Get

@Suite(.serialized) struct RowndTests {

    init() async throws {

    }

    @Test func signOut() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
            }

            let store = Context.currentContext.store

            await MainActor.run {
                store.dispatch(SetAuthState(payload: AuthState(
                    accessToken: generateJwt(expires: NSDate().timeIntervalSince1970),
                    refreshToken: generateJwt(expires: NSDate().timeIntervalSince1970)
                )))
            }

            #expect(store.state?.auth.isAuthenticated == true)

            await Rownd.signOut()

            // Rownd.signOut() schedules the auth-state clear on the main actor, so
            // poll for a short, bounded window until the async state update lands.
            for _ in 0..<20 {
                let isAuthenticated = await MainActor.run {
                    store.state?.auth.isAuthenticated
                }

                if isAuthenticated == false {
                    break
                }

                try await Task.sleep(nanoseconds: 25_000_000)
            }

            await MainActor.run {
                #expect(store.state?.auth.isAuthenticated == false)
            }
        }
    }

    @Test func guestAndAnonymousSignInOpenHubWithAnonymousSignInType() async throws {
        try await withGlobalTestLock {
            for hint in [RowndSignInHint.guest, .anonymous] {
                var capturedPage: HubPageSelector?
                var capturedOptions: RowndSignInOptions?

                Rownd.displayHubHandler = { page, jsFnOptions in
                    capturedPage = page
                    capturedOptions = jsFnOptions as? RowndSignInOptions
                }
                defer { Rownd.displayHubHandler = nil }

                Rownd.requestSignIn(with: hint)

                guard case .signIn = capturedPage else {
                    Issue.record("Expected guest/anonymous sign-in to open Hub sign-in")
                    return
                }

                #expect(capturedOptions?.signInType == .anonymous)
            }
        }
    }

    @Test func legacySmartLinksAreNotHandledBySuperTokensBackedSdk() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }

            #expect(SmartLinks.handleSmartLink(url: URL(string: "https://example.rownd-hub.supertokens.com/sign-in-token")) == false)
            #expect(SmartLinks.handleSmartLink(url: URL(string: "https://example.rownd-hub.supertokens.com/verified/email")) == false)
        }
    }

    @Test func superTokensDeepLinksOpenHubDeepLinkPage() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer {
                Rownd.config = originalConfig
                Rownd.displayHubHandler = originalDisplayHubHandler
            }

            var capturedPage: HubPageSelector?
            Rownd.displayHubHandler = { page, _ in
                capturedPage = page
            }
            Rownd.config.baseUrl = "https://hub.example.com"
            Rownd.config.deepLinkScheme = "rowndsupertokens"

            let handled = SmartLinks.handleSmartLink(
                url: URL(string: "rowndsupertokens://account/login?preAuthSessionId=pid#abc")
            )

            #expect(handled)
            guard case .deepLink = capturedPage else {
                Issue.record("Expected SuperTokens deep link to open Hub deep-link page")
                return
            }
            #expect(Rownd.config.pendingHubDeepLinkUrl?.absoluteString == "https://hub.example.com/account/login?preAuthSessionId=pid#abc")
        }
    }

    @Test func hubUniversalLinksOpenHubDeepLinkPage() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer {
                Rownd.config = originalConfig
                Rownd.displayHubHandler = originalDisplayHubHandler
            }

            var capturedPage: HubPageSelector?
            Rownd.displayHubHandler = { page, _ in
                capturedPage = page
            }
            Rownd.config.baseUrl = "https://staging.supertokens-rownd-hub.pages.dev"

            let handled = SmartLinks.handleSmartLink(
                url: URL(string: "https://staging.supertokens-rownd-hub.pages.dev/account/login?preAuthSessionId=pid#abc")
            )

            #expect(handled)
            guard case .deepLink = capturedPage else {
                Issue.record("Expected Hub universal link to open Hub deep-link page")
                return
            }
            #expect(Rownd.config.pendingHubDeepLinkUrl?.absoluteString == "https://staging.supertokens-rownd-hub.pages.dev/account/login?preAuthSessionId=pid#abc")
        }
    }

    @Test func deepLinkUniversalLinksCanUseSeparateHubIngressDomain() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer {
                Rownd.config = originalConfig
                Rownd.displayHubHandler = originalDisplayHubHandler
            }

            var capturedPage: HubPageSelector?
            Rownd.displayHubHandler = { page, _ in
                capturedPage = page
            }
            Rownd.config.baseUrl = "https://rownd-hub.supertokens.com"
            Rownd.config.signInLinkPattern = ".*\\.rownd-hub\\.supertokens\\.com$"

            let handled = SmartLinks.handleSmartLink(
                url: URL(string: "https://sandbox.rownd-hub.supertokens.com/account/login?preAuthSessionId=pid#abc")
            )

            #expect(handled)
            guard case .deepLink = capturedPage else {
                Issue.record("Expected deep-link universal link to open Hub deep-link page")
                return
            }
            #expect(
                Rownd.config.pendingHubDeepLinkUrl?.absoluteString ==
                    "https://rownd-hub.supertokens.com/account/login?preAuthSessionId=pid#abc"
            )
        }
    }

    @Test func unsupportedSuperTokensDeepLinksAreIgnored() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }

            Rownd.config.deepLinkScheme = "rowndsupertokens"
            Rownd.config.baseUrl = "https://staging.supertokens-rownd-hub.pages.dev"

            #expect(SmartLinks.handleSmartLink(url: URL(string: "rowndsupertokens://account/unknown")) == false)
            #expect(SmartLinks.handleSmartLink(url: URL(string: "other://account/login")) == false)
            #expect(SmartLinks.handleSmartLink(url: URL(string: "https://example.com/account/login")) == false)
            #expect(SmartLinks.handleSmartLink(url: URL(string: "https://staging.supertokens-rownd-hub.pages.dev/account/unknown")) == false)
        }
    }

    @Test func apiDelegatesSkipLegacyHeadersForSuperTokensDomain() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Rownd.config = originalConfig
                Context.currentContext = originalContext
            }

            Rownd.config.appKey = "test-app-key"
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Test App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )
            await MainActor.run {
                Context.currentContext.store.dispatch(
                    SetAuthState(payload: AuthState(accessToken: "legacy-token"))
                )
            }
            Context.currentContext.authenticator = Authenticator(
                sessionBridge: TestSessionBridge(accessToken: "st-token").client
            )

            var authenticatedRequest = URLRequest(url: URL(string: "https://api.example.com/auth/plugin/rownd/user")!)
            try await RowndApiClientDelegate().client(testAPIClient(), willSendRequest: &authenticatedRequest)

            #expect(authenticatedRequest.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(authenticatedRequest.value(forHTTPHeaderField: "X-Rownd-App-Key") == nil)

            var unauthenticatedRequest = URLRequest(url: URL(string: "https://api.example.com/auth/plugin/rownd/app-config")!)
            try await RowndUnauthenticatedApiClientDelegate().client(
                testAPIClient(),
                willSendRequest: &unauthenticatedRequest
            )

            #expect(unauthenticatedRequest.value(forHTTPHeaderField: "X-Rownd-App-Key") == nil)
        }
    }

    @Test func apiDelegatesKeepLegacyHeadersForNonSuperTokensDomain() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Rownd.config = originalConfig
                Context.currentContext = originalContext
            }

            Rownd.config.appKey = "test-app-key"
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Test App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )
            let accessToken = generateJwt(expires: Date(timeIntervalSinceNow: 1000).timeIntervalSince1970)
            await MainActor.run {
                Context.currentContext.store.dispatch(
                    SetAuthState(payload: AuthState(accessToken: accessToken))
                )
            }
            let bridge = TestSessionBridge(accessToken: accessToken)
            Context.currentContext.authenticator = Authenticator(sessionBridge: bridge.client)

            var authenticatedRequest = URLRequest(url: URL(string: "https://api.rownd.io/me")!)
            try await RowndApiClientDelegate().client(testAPIClient(), willSendRequest: &authenticatedRequest)

            #expect(authenticatedRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessToken)")
            #expect(authenticatedRequest.value(forHTTPHeaderField: "X-Rownd-App-Key") == "test-app-key")

            var unauthenticatedRequest = URLRequest(url: URL(string: "https://api.rownd.io/hub/app-config")!)
            try await RowndUnauthenticatedApiClientDelegate().client(
                testAPIClient(),
                willSendRequest: &unauthenticatedRequest
            )

            #expect(unauthenticatedRequest.value(forHTTPHeaderField: "X-Rownd-App-Key") == "test-app-key")
        }
    }

}

private func testAPIClient() -> APIClient {
    APIClient(baseURL: URL(string: "https://api.example.com"))
}
