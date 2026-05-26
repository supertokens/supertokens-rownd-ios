import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct SuperTokensThirdPartySignInClientTests {
    @Test func googleExchangePostsSigninupPayload() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":true}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: session
            )

            let response = try await client.signInWithGoogle(idToken: "google-id-token")

            #expect(response.userType == .NewUser)
            let request = try #require(ThirdPartySignInURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://auth.example.com/auth/signinup")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "rid") == "thirdparty")
            #expect(request.value(forHTTPHeaderField: "fdi-version") == "4.1")

            let body = try #require(ThirdPartySignInURLProtocol.lastRequestBody)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["thirdPartyId"] as? String == "google")
            let tokens = json?["oAuthTokens"] as? [String: Any]
            #expect(tokens?["id_token"] as? String == "google-id-token")
            #expect(json?["redirectURIInfo"] == nil)
        }
    }

    @Test func appleExchangePostsAuthorizationCodeSigninupPayload() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":true}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: session
            )

            let response = try await client.signInWithApple(authorizationCode: "apple-auth-code")

            #expect(response.userType == .NewUser)
            let request = try #require(ThirdPartySignInURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://auth.example.com/auth/signinup")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "rid") == "thirdparty")

            let body = try #require(ThirdPartySignInURLProtocol.lastRequestBody)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["thirdPartyId"] as? String == "apple")
            #expect(json?["oAuthTokens"] == nil)

            let redirectURIInfo = json?["redirectURIInfo"] as? [String: Any]
            #expect(redirectURIInfo?["redirectURIOnProviderDashboard"] as? String == "")
            let queryParams = redirectURIInfo?["redirectURIQueryParams"] as? [String: Any]
            #expect(queryParams?["code"] as? String == "apple-auth-code")
        }
    }

    @Test func googleExchangeMapsExistingUsers() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":false}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: session
            )

            let response = try await client.signInWithGoogle(idToken: "google-id-token")

            #expect(response.userType == .ExistingUser)
        }
    }

    @Test func exchangeNormalizesBasePathSlashes() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":true}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/custom-auth/",
                session: session
            )

            _ = try await client.signInWithGoogle(idToken: "google-id-token")

            let request = try #require(ThirdPartySignInURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://auth.example.com/custom-auth/signinup")
        }
    }

    @Test func exchangeHandlesRootBasePath() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":true}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/",
                session: session
            )

            _ = try await client.signInWithGoogle(idToken: "google-id-token")

            let request = try #require(ThirdPartySignInURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://auth.example.com/signinup")
        }
    }
}

private final class ThirdPartySignInURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _lastRequest: URLRequest?
    private static var _lastRequestBody: Data?

    static var responseBody = Data()
    static var responseStatusCode = 200

    static var lastRequest: URLRequest? {
        lock.withLock { _lastRequest }
    }

    static var lastRequestBody: Data? {
        lock.withLock { _lastRequestBody }
    }

    static func reset() {
        lock.withLock {
            _lastRequest = nil
            _lastRequestBody = nil
            responseBody = Data()
            responseStatusCode = 200
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBodyStream.flatMap { stream -> Data? in
            stream.open()
            defer { stream.close() }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 {
                    break
                }
                data.append(buffer, count: count)
            }
            return data
        } ?? request.httpBody

        Self.lock.withLock {
            Self._lastRequest = request
            Self._lastRequestBody = body
        }

        let statusCode = Self.lock.withLock { Self.responseStatusCode }
        let responseBody = Self.lock.withLock { Self.responseBody }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
