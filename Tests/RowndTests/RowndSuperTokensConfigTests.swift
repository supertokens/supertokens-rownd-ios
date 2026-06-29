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

    @Test func validateSuperTokensConfigRequiresNonEmptyFields() async throws {
        try await withGlobalTestLock {
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
    }

    @Test func configureStoresSuperTokensConfigBeforeAppConfigFetch() async throws {
        try await withGlobalTestLock {
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
                "name": "Example App",
                "config": {
                  "supertokens": {
                    "appInfo": {
                      "apiDomain": "https://api.example.com",
                      "apiBasePath": "/auth"
                    }
                  }
                }
              }
            }
            """.data(using: .utf8)!

            Rownd.config = RowndConfig()
            Rownd.config.enableSmartLinkPasteBehavior = false
            AppConfigRequestURLProtocol.responseData = responseData
            AppConfig.testingProtocolClasses = [AppConfigRequestURLProtocol.self]
            Rownd.apiClient = APIClient(baseURL: URL(string: "https://ignored.example.com")!) {
                $0.sessionConfiguration.protocolClasses = [AppConfigRequestURLProtocol.self]
                $0.sessionConfiguration.urlCache = nil
            }
            Rownd.isSuperTokensInitialized = true

            _ = await Rownd.configure(appKey: "app_test", supertokens: expectedConfig)

            let appConfigURL = try AppConfig.appConfigURL().absoluteString
            #expect(Rownd.config.supertokens == expectedConfig)
            #expect(Rownd.config.apiUrl == expectedConfig.apiDomain)
            #expect(appConfigURL == "https://api.example.com/auth/plugin/rownd/app-config")
        }
    }

    @Test func initializeSuperTokensUsesConfiguredBootstrapValues() async throws {
        try await withGlobalTestLock {
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

            let didInitialize = try Rownd.initializeSuperTokensIfNeeded()
            #expect(didInitialize)

            var request = URLRequest(url: URL(string: "https://api.example.com/auth/me")!)
            request.setValue("anti-csrf", forHTTPHeaderField: "rid")

            #expect(SuperTokensURLProtocol.canInit(with: request))
            #expect(!SuperTokensURLProtocol.canInit(with: URLRequest(url: URL(string: "https://api.other.com/auth/me")!)))
        }
    }

    @Test func initializeSuperTokensOnlyRunsOncePerProcess() async throws {
        try await withGlobalTestLock {
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

            let firstInitialize = try Rownd.initializeSuperTokensIfNeeded()
            let secondInitialize = try Rownd.initializeSuperTokensIfNeeded()
            #expect(firstInitialize)
            #expect(!secondInitialize)
        }
    }

    @Test func rowndConfigEncodesSuperTokensAppInfoForHub() async throws {
        try await withGlobalTestLock {
            var config = RowndConfig()
            config.enableDebugMode = true
            config.supertokens = RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/custom-auth"
            )

            let json = await MainActor.run { config.toJson() }
            let decoded = try decodeJsonObject(json)
            let supertokens = try #require(decoded["supertokens"] as? [String: Any])
            let appInfo = try #require(supertokens["appInfo"] as? [String: Any])

            #expect(appInfo["apiDomain"] as? String == "https://api.example.com")
            #expect(appInfo["apiBasePath"] as? String == "/custom-auth")
            #expect(supertokens["appName"] == nil)
            #expect(decoded["enableDebugMode"] == nil)
        }
    }

    @Test func hubLoaderUrlIncludesRequiredScriptQueryParams() async throws {
        try await withGlobalTestLock {
            var config = RowndConfig()
            config.appKey = "app_test"
            config.supertokens = RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/custom-auth"
            )

            let url = try #require(HubViewController.buildHubLoaderUrl(
                baseUrl: "https://hub.example.com",
                config: config,
                base64EncodedConfig: "encoded-config",
                signInHash: "encoded-sign-in"
            ))
            let queryItems = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value) })

            #expect(url.url?.absoluteString.starts(with: "https://hub.example.com/mobile_app?") == true)
            #expect(queryItems["config"] == "encoded-config")
            #expect(queryItems["sign_in"] == "encoded-sign-in")
            #expect(queryItems["appKey"] == "app_test")
            #expect(queryItems["apiDomain"] == "https://api.example.com")
            #expect(queryItems["apiBasePath"] == "/custom-auth")
        }
    }

    @Test func repeatedConfigureKeepsSuperTokensInitializationGuardSet() async throws {
        try await withGlobalTestLock {
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

            await MainActor.run {
                Context.currentContext.store.dispatch(SetAppConfig(payload: AppConfigState()))
                Context.currentContext.store.dispatch(SetAuthState(payload: AuthState()))
                Context.currentContext.store.dispatch(SetClockSync(clockSyncState: .synced))
            }

            AppConfigRequestURLProtocol.responseData = Self.appConfigResponseData
            AppConfig.testingProtocolClasses = [AppConfigRequestURLProtocol.self]
            Rownd.apiClient = APIClient(baseURL: URL(string: "https://ignored.example.com")!) {
                $0.sessionConfiguration.protocolClasses = [AppConfigRequestURLProtocol.self]
                $0.sessionConfiguration.urlCache = nil
            }

            Rownd.config = RowndConfig()
            Rownd.config.apiUrl = "https://stale.example.com"
            Rownd.config.enableSmartLinkPasteBehavior = false
            Rownd.isSuperTokensInitialized = false

            _ = await Rownd.configure(
                appKey: "app_test",
                supertokens: RowndSuperTokensConfig(
                    appName: "Example App",
                    apiDomain: "https://first.example.com",
                    apiBasePath: "/auth"
                )
            )

            _ = await Rownd.configure(
                appKey: "app_test",
                supertokens: RowndSuperTokensConfig(
                    appName: "Example App",
                    apiDomain: "https://second.example.com",
                    apiBasePath: "/auth"
                )
            )

            #expect(Rownd.isSuperTokensInitialized)
            #expect(Rownd.config.supertokens.apiDomain == "https://second.example.com")
            #expect(Rownd.config.apiUrl == "https://second.example.com")
        }
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

    private func decodeJsonObject(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private static let appConfigResponseData = """
    {
      "app": {
        "id": "app_test",
        "name": "Example App",
        "config": {
          "supertokens": {
            "appInfo": {
              "apiDomain": "https://first.example.com",
              "apiBasePath": "/auth"
            }
          }
        }
      }
    }
    """.data(using: .utf8)!
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
