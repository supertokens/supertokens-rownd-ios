//
//  RphInitTests.swift
//  Rownd
//
//  Created by Bobby on 4/14/25.
//

import Testing
@testable import Rownd
import Foundation

@Suite(.serialized) struct RphInitTests {
    @Test func testValueForURLFragment() async throws {
        let rphInit = RphInit(
            accessToken: "accessToken",
            refreshToken: "refreshToken",
            frontToken: "frontToken",
            antiCSRF: "antiCSRF",
            appId: "app1",
            appUserId: "user1"
        )
        let str = try rphInit.valueForURLFragment()

        #expect(str.starts(with: "gz."), "value should contain 'gz.' prefix")
        let base64String = str.components(separatedBy: "gz.")[1]
        let gzippedData = Data(base64Encoded: base64String)
        let gunzippedData = try gzippedData?.gunzipped()
        let decoded = try JSONDecoder().decode([String: String].self, from: gunzippedData!)
        let expected: [String: String] = [
            "access_token": "accessToken",
            "refresh_token": "refreshToken",
            "front_token": "frontToken",
            "anti_csrf": "antiCSRF",
            "app_id": "app1",
            "app_user_id": "user1"
        ]

        #expect(decoded == expected)
    }

    @Test func authStateUsesAccessTokenAppUserIdWhenUserDataIsNotLoaded() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
            }

            let store = Context.currentContext.store
            let accessToken = try makeUnsignedJwt(payload: ["https://auth.rownd.io/app_user_id": "jwt-user-id"])

            await MainActor.run {
                store.dispatch(SetAppConfig(payload: AppConfigState(id: "app1")))
                store.dispatch(SetAuthState(payload: AuthState(accessToken: accessToken, refreshToken: "refreshToken")))
            }

            let rphInit = try #require(store.state.auth.toRphInitHash())
            let decoded = try decodeRphInit(rphInit)

            #expect(decoded["app_user_id"] == "jwt-user-id")
        }
    }

    private func decodeRphInit(_ value: String) throws -> [String: String] {
        #expect(value.starts(with: "gz."), "value should contain 'gz.' prefix")
        let base64String = value.components(separatedBy: "gz.")[1]
        let gzippedData = try #require(Data(base64Encoded: base64String))
        let gunzippedData = try gzippedData.gunzipped()
        return try JSONDecoder().decode([String: String].self, from: gunzippedData)
    }

    private func makeUnsignedJwt(payload: [String: String]) throws -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        return [base64URL(headerData), base64URL(payloadData), "signature"].joined(separator: ".")
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
