//
//  RowndSuperTokensConfigTests.swift
//  RowndTests
//

import Foundation
import Get
import SuperTokensIOS
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
        let originalSuperTokensInitialized = Rownd.isSuperTokensInitialized
        defer {
            Rownd.apiClient = originalApiClient
            Rownd.config = originalConfig
            Rownd.isSuperTokensInitialized = originalSuperTokensInitialized
            AppConfig.testingProtocolClasses = nil
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
        AppConfig.testingProtocolClasses = [AppConfigRequestURLProtocol.self]
        Rownd.apiClient = APIClient(baseURL: URL(string: "https://ignored.example.com")!) {
            $0.sessionConfiguration.protocolClasses = [AppConfigRequestURLProtocol.self]
            $0.sessionConfiguration.urlCache = nil
        }
        Rownd.isSuperTokensInitialized = true

        _ = await Rownd.configure(appKey: "app_test", supertokens: expectedConfig)

        #expect(Rownd.config.supertokens == expectedConfig)
        #expect(try AppConfig.appConfigURL().absoluteString == "https://api.example.com/auth/plugin/rownd/app-config")
    }

    @Test func initializeSuperTokensUsesConfiguredBootstrapValues() throws {
        let originalConfig = Rownd.config
        let originalSuperTokensInitialized = Rownd.isSuperTokensInitialized
        defer {
            Rownd.config = originalConfig
            Rownd.isSuperTokensInitialized = originalSuperTokensInitialized
        }

        Rownd.config.supertokens = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com",
            apiBasePath: "/auth"
        )
        Rownd.isSuperTokensInitialized = false

        #expect(try Rownd.initializeSuperTokensIfNeeded())

        var request = URLRequest(url: URL(string: "https://api.example.com/auth/me")!)
        request.setValue("anti-csrf", forHTTPHeaderField: "rid")

        #expect(SuperTokensURLProtocol.canInit(with: request))
        #expect(!SuperTokensURLProtocol.canInit(with: URLRequest(url: URL(string: "https://api.other.com/auth/me")!)))
    }

    @Test func initializeSuperTokensOnlyRunsOncePerProcess() throws {
        let originalConfig = Rownd.config
        let originalSuperTokensInitialized = Rownd.isSuperTokensInitialized
        defer {
            Rownd.config = originalConfig
            Rownd.isSuperTokensInitialized = originalSuperTokensInitialized
        }

        Rownd.config.supertokens = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com",
            apiBasePath: "/auth"
        )
        Rownd.isSuperTokensInitialized = false

        #expect(try Rownd.initializeSuperTokensIfNeeded())
        #expect(try !Rownd.initializeSuperTokensIfNeeded())
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
    static var requestedURL: String?
    static var requestedAppKeyHeader: String?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/auth/plugin/rownd/app-config"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.observedConfigDuringFetch = Rownd.config.supertokens
        Self.requestedURL = request.url?.absoluteString
        Self.requestedAppKeyHeader = request.value(forHTTPHeaderField: "X-Rownd-App-Key")

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
        requestedURL = nil
        requestedAppKeyHeader = nil
    }
}
