//
//  RowndSuperTokensConfigTests.swift
//  RowndTests
//

import Foundation
import Get
import Testing

@testable import Rownd

@Suite(.serialized) struct RowndSuperTokensConfigTests {
    init() async throws {}

    @Test func validateSuperTokensConfigRequiresNonEmptyFields() throws {
        let validConfig = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com"
        )

        #expect(try Rownd.validateSuperTokensConfig(validConfig) == validConfig)
        try expectValidationError(
            RowndSuperTokensConfig(appName: "", apiDomain: "https://api.example.com"),
            expectedMessage: "SuperTokens appName must not be empty"
        )
        try expectValidationError(
            RowndSuperTokensConfig(appName: "Example App", apiDomain: ""),
            expectedMessage: "SuperTokens apiDomain must not be empty"
        )
        try expectValidationError(
            RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: ""
            ),
            expectedMessage: "SuperTokens apiBasePath must not be empty"
        )
    }

    @Test func configureStoresSuperTokensConfigBeforeAppConfigFetch() async throws {
        let originalApiClient = Rownd.apiClient
        let originalConfig = Rownd.config
        defer {
            Rownd.apiClient = originalApiClient
            Rownd.config = originalConfig
            AppConfigRequestURLProtocol.reset()
        }

        let store = Context.currentContext.store
        await MainActor.run {
            store.dispatch(SetAppConfig(payload: AppConfigState()))
            store.dispatch(SetAuthState(payload: AuthState()))
            store.dispatch(SetClockSync(clockSyncState: .synced))
        }

        let expectedConfig = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com",
            apiBasePath: "/auth"
        )

        let responseData = """
        {
          "app": {
            "id": "app_test",
            "name": "Example App"
          }
        }
        """.data(using: .utf8)!

        Rownd.config = RowndConfig()
        AppConfigRequestURLProtocol.responseData = responseData
        Rownd.apiClient = APIClient(baseURL: URL(string: "https://api.rownd.io")!) {
            $0.sessionConfiguration.protocolClasses = [AppConfigRequestURLProtocol.self]
            $0.sessionConfiguration.urlCache = nil
        }

        _ = await Rownd.configure(appKey: "app_test", supertokens: expectedConfig)

        #expect(AppConfigRequestURLProtocol.observedConfigDuringFetch == expectedConfig)
        #expect(Rownd.config.supertokens == expectedConfig)
    }

    private func expectValidationError(
        _ config: RowndSuperTokensConfig,
        expectedMessage: String
    ) throws {
        do {
            _ = try Rownd.validateSuperTokensConfig(config)
            Issue.record("Expected validation to fail")
        } catch let error as RowndError {
            #expect(error.description == expectedMessage)
        } catch {
            Issue.record("Unexpected validation error: \(error)")
        }
    }
}

private final class AppConfigRequestURLProtocol: URLProtocol {
    static var observedConfigDuringFetch: RowndSuperTokensConfig?
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString == "https://api.rownd.io/hub/app-config"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.observedConfigDuringFetch = Rownd.config.supertokens

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        observedConfigDuringFetch = nil
        responseData = Data()
    }
}
