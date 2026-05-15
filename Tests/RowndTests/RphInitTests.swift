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
}
