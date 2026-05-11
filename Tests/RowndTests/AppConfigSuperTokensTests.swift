//
//  AppConfigSuperTokensTests.swift
//  RowndTests
//

import Foundation
import Testing

@testable import Rownd

struct AppConfigSuperTokensTests {
    @Test func decodeAppConfigWithMatchingSuperTokensConfig() throws {
        Rownd.config = RowndConfig()
        Rownd.config.supertokens = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com",
            apiBasePath: "/auth"
        )

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

    @Test func decodeAppConfigWithoutSuperTokensConfigRemainsValid() throws {
        Rownd.config = RowndConfig()
        Rownd.config.supertokens = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com",
            apiBasePath: "/auth"
        )

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
        #expect(throws: Never.self) {
            try AppConfig.validateSuperTokensConfig(appConfig)
        }
    }

    @Test func conflictingSuperTokensApiDomainFailsValidation() throws {
        Rownd.config = RowndConfig()
        Rownd.config.supertokens = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com",
            apiBasePath: "/auth"
        )

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

    @Test func conflictingSuperTokensApiBasePathFailsValidation() throws {
        Rownd.config = RowndConfig()
        Rownd.config.supertokens = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com",
            apiBasePath: "/auth"
        )

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

    private func decodeAppConfig(from json: String) throws -> AppConfigResponse {
        try JSONDecoder().decode(AppConfigResponse.self, from: Data(json.utf8))
    }
}
