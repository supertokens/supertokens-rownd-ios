import Foundation
import SuperTokensIOS
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

        EmailVerificationResponseURLProtocol.responseBody = #"{"status":"OK"}"#.data(using: .utf8)!
        try await HubWebViewController.performNativeEmailVerification(
            request: request,
            session: session,
            getAccessToken: accessTokenSequence("old-access-token", "new-access-token"),
            getRefreshToken: { "new-refresh-token" },
            getFrontToken: { "new-front-token" },
            syncAuthState: { true }
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

        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence("same-token", "same-token"),
                getRefreshToken: { "refresh-token" },
                getFrontToken: { "front-token" },
                syncAuthState: { true }
            )
        }
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence("old-token", nil),
                getRefreshToken: { "refresh-token" },
                getFrontToken: { "front-token" },
                syncAuthState: { true }
            )
        }
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence("old-token", "new-token"),
                getRefreshToken: { nil },
                getFrontToken: { "front-token" },
                syncAuthState: { true }
            )
        }
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence("old-token", "new-token"),
                getRefreshToken: { "refresh-token" },
                getFrontToken: { "" },
                syncAuthState: { true }
            )
        }
        await #expect(throws: (any Error).self) {
            try await HubWebViewController.performNativeEmailVerification(
                request: request,
                session: session,
                getAccessToken: accessTokenSequence("old-token", "new-token"),
                getRefreshToken: { "refresh-token" },
                getFrontToken: { "front-token" },
                syncAuthState: { false }
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
}

private func accessTokenSequence(_ values: String?...) -> () async -> String? {
    var values = values
    return { values.removeFirst() }
}

private final class EmailVerificationResponseURLProtocol: URLProtocol {
    static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
