//
//  RowndSuperTokensConfigTests.swift
//  RowndTests
//

import Foundation
import Get
import Mocker
import Testing

@testable import Rownd

@Suite(.serialized) struct RowndSuperTokensConfigTests {
    init() async throws {
        Mocker.removeAll()
    }

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
            Mocker.removeAll()
        }

        let store = Context.currentContext.store
        await MainActor.run {
            store.dispatch(SetAppConfig(payload: AppConfigState()))
            store.dispatch(SetAuthState(payload: AuthState()))
            store.dispatch(SetClockSync(clockSyncState: .synced))
        }

        Rownd.config = RowndConfig()
        Rownd.apiClient = APIClient.mock()

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

        var observedConfigDuringFetch: RowndSuperTokensConfig?
        var mock = Mock(
            url: URL(string: "https://api.rownd.io/hub/app-config")!,
            ignoreQuery: true,
            contentType: .json,
            statusCode: 200,
            data: [.get: responseData]
        )

        mock.onRequestHandler = OnRequestHandler(requestCallback: { _ in
            observedConfigDuringFetch = Rownd.config.supertokens
        })

        mock.register()

        _ = await Rownd.configure(appKey: "app_test", supertokens: expectedConfig)

        #expect(observedConfigDuringFetch == expectedConfig)
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
