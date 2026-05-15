//
//  AppConfigSuperTokensTests.swift
//  RowndTests
//

import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct AppConfigSuperTokensTests {
    @Test func appConfigURLUsesDefaultBasePath() throws {
        try withSuperTokensConfig(
            RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com"
            )
        ) {
            let url = try AppConfig.appConfigURL()
            #expect(url.absoluteString == "https://api.example.com/auth/plugin/rownd/app-config")
        }
    }

    @Test func appConfigURLUsesCustomBasePath() throws {
        try withSuperTokensConfig(
            RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/custom-auth"
            )
        ) {
            let url = try AppConfig.appConfigURL()
            #expect(url.absoluteString == "https://api.example.com/custom-auth/plugin/rownd/app-config")
        }
    }

    @Test func decodeAppConfigWithMatchingSuperTokensConfig() throws {
        try withSuperTokensConfig(
            RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )
        ) {
            let appConfig = try decodeAppConfig(
                from: """
                {
                  "app": {
                    "id": "app_test",
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
                """
            )

            #expect(appConfig.app.config?.supertokens?.appInfo.apiDomain == "https://api.example.com")
            #expect(appConfig.app.config?.supertokens?.appInfo.apiBasePath == "/auth")
            #expect(throws: Never.self) {
                try AppConfig.validateSuperTokensConfig(appConfig)
            }
        }
    }

    @Test func decodeAppConfigWithoutSuperTokensConfigFailsValidation() throws {
        try withSuperTokensConfig(
            RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )
        ) {
            let appConfig = try decodeAppConfig(
                from: """
                {
                  "app": {
                    "id": "app_test",
                    "config": {
                      "subdomain": "example"
                    }
                  }
                }
                """
            )

            #expect(appConfig.app.config?.supertokens == nil)
            do {
                try AppConfig.validateSuperTokensConfig(appConfig)
                Issue.record("Expected missing SuperTokens config validation to fail")
            } catch let error as RowndError {
                #expect(error.description == "App config is missing required SuperTokens configuration")
            }
        }
    }

    @Test func conflictingSuperTokensApiDomainFailsValidation() throws {
        try withSuperTokensConfig(
            RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )
        ) {
            let appConfig = try decodeAppConfig(
                from: """
                {
                  "app": {
                    "id": "app_test",
                    "config": {
                      "supertokens": {
                        "appInfo": {
                          "apiDomain": "https://different.example.com",
                          "apiBasePath": "/auth"
                        }
                      }
                    }
                  }
                }
                """
            )

            do {
                try AppConfig.validateSuperTokensConfig(appConfig)
                Issue.record("Expected apiDomain validation to fail")
            } catch let error as RowndError {
                #expect(
                    error.description
                        == "App config SuperTokens apiDomain https://different.example.com does not match configured value https://api.example.com"
                )
            }
        }
    }

    @Test func conflictingSuperTokensApiBasePathFailsValidation() throws {
        try withSuperTokensConfig(
            RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )
        ) {
            let appConfig = try decodeAppConfig(
                from: """
                {
                  "app": {
                    "id": "app_test",
                    "config": {
                      "supertokens": {
                        "appInfo": {
                          "apiDomain": "https://api.example.com",
                          "apiBasePath": "/custom-auth"
                        }
                      }
                    }
                  }
                }
                """
            )

            do {
                try AppConfig.validateSuperTokensConfig(appConfig)
                Issue.record("Expected apiBasePath validation to fail")
            } catch let error as RowndError {
                #expect(
                    error.description
                        == "App config SuperTokens apiBasePath /custom-auth does not match configured value /auth"
                )
            }
        }
    }

    private func decodeAppConfig(from json: String) throws -> AppConfigResponse {
        try JSONDecoder().decode(AppConfigResponse.self, from: Data(json.utf8))
    }

    private func withSuperTokensConfig(
        _ config: RowndSuperTokensConfig,
        _ operation: () throws -> Void
    ) throws {
        try withSynchronousGlobalTestLock {
            let originalConfig = Rownd.config
            defer {
                Rownd.config = originalConfig
            }

            Rownd.config = RowndConfig()
            Rownd.config.supertokens = config

            try operation()
        }
    }
}
