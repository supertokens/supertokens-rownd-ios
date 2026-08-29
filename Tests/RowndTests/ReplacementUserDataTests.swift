import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct ReplacementUserDataTests {
    @Test func replacementProfile404DoesNotSignOutAuthenticatedState() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let originalConfig = Rownd.config
            let store = createStore()
            _ = Context(store)
            defer {
                Context.currentContext = originalContext
                Rownd.config = originalConfig
                UserData.testingRequestSession = nil
            }

            var config = RowndConfig()
            config.supertokens = RowndSuperTokensConfig(
                appName: "Replacement profile tests",
                apiDomain: "https://auth.example.com"
            )
            Rownd.config = config
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [ReplacementProfile404URLProtocol.self]
            UserData.testingRequestSession = URLSession(configuration: sessionConfiguration)

            await MainActor.run {
                store.dispatch(SetAuthState(payload: AuthState(accessToken: "replacement-token")))
            }

            let response = try await UserData.fetchReplacementUserData(store.state)

            #expect(response == nil)
            await MainActor.run {
                #expect(store.state.auth.accessToken == "replacement-token")
                #expect(store.state.auth.isAuthenticated)
            }
        }
    }
}

private final class ReplacementProfile404URLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/auth/plugin/rownd/user"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"NOT_FOUND"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
