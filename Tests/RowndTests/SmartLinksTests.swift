import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct SmartLinksTests {
    @Test func pendingEmailVerificationCustomLinkPreservesQueryWithoutEmbeddingNativeSession() async throws {
        try await withSmartLinksTestConfig {
            let sourceUrl = try #require(URL(string:
                "rownd-smart-links-tests://account/verify-email?token=email-token&rowndPendingVerificationId=pending-123&redirect=https%3A%2F%2Fexample.com%2Fdone"
            ))

            let handled = SmartLinks.handleSmartLink(url: sourceUrl)

            #expect(handled)
            let mappedUrl = try #require(Rownd.config.pendingHubDeepLinkUrl)
            let components = try #require(URLComponents(url: mappedUrl, resolvingAgainstBaseURL: false))
            #expect(components.scheme == "https")
            #expect(components.host == "hub.smart-links.test")
            #expect(components.path == "/account/verify-email")
            #expect(components.queryItems == [
                URLQueryItem(name: "token", value: "email-token"),
                URLQueryItem(name: "rowndPendingVerificationId", value: "pending-123"),
                URLQueryItem(name: "redirect", value: "https://example.com/done"),
            ])
            #expect(components.fragment == nil)
        }
    }

    @Test func unmarkedEmailVerificationUniversalLinkKeepsItsOriginalFragment() async throws {
        try await withSmartLinksTestConfig {
            let sourceUrl = try #require(URL(string:
                "https://links.rownd-hub.supertokens.com/account/verify-email?token=ordinary-token#verification-state"
            ))

            let handled = SmartLinks.handleSmartLink(url: sourceUrl)

            #expect(handled)
            let mappedUrl = try #require(Rownd.config.pendingHubDeepLinkUrl)
            #expect(mappedUrl.absoluteString ==
                "https://hub.smart-links.test/account/verify-email?token=ordinary-token#verification-state"
            )
        }
    }

    @Test func authenticatedPasswordlessLoginKeepsItsHashFragment() async throws {
        try await withSmartLinksTestConfig {
            let sourceUrl = try #require(URL(string:
                "rownd-smart-links-tests://account/login#preAuthSessionId=passwordless-session&linkCode=passwordless-code"
            ))

            let handled = SmartLinks.handleSmartLink(url: sourceUrl)

            #expect(handled)
            let mappedUrl = try #require(Rownd.config.pendingHubDeepLinkUrl)
            #expect(mappedUrl.absoluteString ==
                "https://hub.smart-links.test/account/login#preAuthSessionId=passwordless-session&linkCode=passwordless-code"
            )
        }
    }

    @Test func sameLinkCanBeRetried() async throws {
        try await withSmartLinksTestConfig {
            let sourceUrl = try #require(URL(string:
                "rownd-smart-links-tests://account/verify-email?token=email-token"
            ))
            var displayCount = 0
            Rownd.displayHubHandler = { _, _ in displayCount += 1 }

            #expect(SmartLinks.handleSmartLink(url: sourceUrl))
            #expect(SmartLinks.handleSmartLink(url: sourceUrl))
            #expect(displayCount == 2)
        }
    }
}

private func withSmartLinksTestConfig(_ operation: @escaping @Sendable () throws -> Void) async throws {
    try await withGlobalTestLock {
        let originalConfig = Rownd.config
        let originalDisplayHubHandler = Rownd.displayHubHandler

        defer {
            Rownd.config = originalConfig
            Rownd.displayHubHandler = originalDisplayHubHandler
        }

        Rownd.config.baseUrl = "https://hub.smart-links.test"
        Rownd.config.deepLinkScheme = "rownd-smart-links-tests"
        Rownd.displayHubHandler = { _, _ in }

        try operation()
    }
}
