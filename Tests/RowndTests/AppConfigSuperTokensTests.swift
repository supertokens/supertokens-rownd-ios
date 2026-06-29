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

    @Test func pluginRoutesHandleRootBasePath() throws {
        try withSuperTokensConfig(
            RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/"
            )
        ) {
            let url = try SuperTokensPluginRoutes.url("/user")
            #expect(url.absoluteString == "https://api.example.com/plugin/rownd/user")
        }
    }

    @Test func pluginRoutesNormalizeBasePathSlashes() throws {
        try withSuperTokensConfig(
            RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/custom-auth/"
            )
        ) {
            let url = try SuperTokensPluginRoutes.url("user")
            #expect(url.absoluteString == "https://api.example.com/custom-auth/plugin/rownd/user")
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

    @Test func decodeAppConfigWithoutSuperTokensConfigUsesSdkBootstrapConfig() throws {
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
            #expect(throws: Never.self) {
                try AppConfig.validateSuperTokensConfig(appConfig)
            }
        }
    }

    @Test func decodePluginAppConfigGoogleMethodShape() throws {
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
                  "status": "OK",
                  "config_type": "app",
                  "app": {
                    "id": "key_test",
                    "name": "Rownd iOS Example",
                    "schema": {
                      "email": { "display_name": "Email", "type": "string", "owned_by": "user" },
                      "google_id": { "display_name": "Google ID", "type": "string", "owned_by": "app" }
                    },
                    "config": {
                      "customizations": { "primary_color": "#5b5bd6" },
                      "hub": {
                        "customizations": {
                          "rounded_corners": true,
                          "visual_swoops": true,
                          "blur_background": true,
                          "dark_mode": "auto"
                        },
                        "auth": {
                          "sign_in_methods": {
                            "email": { "enabled": true },
                            "phone": { "enabled": true },
                            "google": {
                              "enabled": true,
                              "client_id": "web-client.apps.googleusercontent.com",
                              "ios_client_id": "ios-client.apps.googleusercontent.com",
                              "scopes": []
                            },
                            "apple": {
                              "enabled": false,
                              "client_id": "",
                              "web_client_type": "web",
                              "ios_client_type": "ios",
                              "android_client_type": "android"
                            },
                            "anonymous": { "enabled": true, "type": "guest", "display_name": "Continue as guest" }
                          },
                          "additional_fields": [],
                          "show_app_icon": false
                        }
                      }
                    }
                  }
                }
                """
            )

            #expect(throws: Never.self) {
                try AppConfig.validateSuperTokensConfig(appConfig)
            }

            let methods = try #require(appConfig.app.config?.hub?.auth?.signInMethods)
            #expect(methods.email?.enabled == true)
            #expect(methods.phone?.enabled == true)
            #expect(methods.google?.enabled == true)
            #expect(methods.google?.serverClientId == "web-client.apps.googleusercontent.com")
            #expect(methods.google?.iosClientId == "ios-client.apps.googleusercontent.com")
            #expect(methods.google?.scopes == [])
            #expect(methods.apple?.enabled == false)
            #expect(methods.apple?.webClientType == "web")
            #expect(methods.apple?.iosClientType == "ios")
            #expect(methods.apple?.androidClientType == "android")
            #expect(methods.anonymous?.enabled == true)
            #expect(methods.anonymous?.type == "guest")
            #expect(methods.anonymous?.displayName == "Continue as guest")
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
