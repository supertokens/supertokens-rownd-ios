//
//  RowndTests.swift
//  RowndTests
//
//  Created by Matt Hamann on 7/15/22.
//

import Testing
@testable import Rownd
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

            Rownd.signOut()

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
