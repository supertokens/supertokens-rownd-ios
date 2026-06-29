//
//  AutomationTests.swift
//
//
//  Created by Michael Murray on 8/19/24.
//

import XCTest

@testable import Rownd

final class UserTests: XCTestCase {
    
    let userStringWithIsLoading = """
    {\"meta\":{},\"data\":{},\"isLoading\":false}
    """

    func testDecodingUserWithIsLoading() {
        do {
            let decoder = JSONDecoder()
            let userState = try decoder.decode(
                UserState.self,
                from: (userStringWithIsLoading.data(using: .utf8) ?? Data())
            )
            
            XCTAssertTrue(userState.isLoading == false)
            
        } catch {
            XCTFail("Failed to decode user string \(error)")
        }
        
    }
    
    
    let userStringWithoutIsLoading = """
        {\"meta\":{},\"data\":{}}
    """

    func testDecodingUserWithoutIsLoading() {
        do {
            let decoder = JSONDecoder()
            let userState = try decoder.decode(
                UserState.self,
                from: (userStringWithoutIsLoading.data(using: .utf8) ?? Data())
            )
            
            XCTAssertTrue(userState.isLoading == false)
            
        } catch {
            XCTFail("Failed to decode user string \(error)")
        }
        
    }
    
    let userStringWithDataAndWithoutIsLoading = """
        {\"data\":{\"user_id\":\"user_totlsniyvtakfd1y1cad6zpe\",\"anonymous_id\":\"anon_30df55f5-9567-4d5c-bc2e-2c277c075a30\"},\"meta\":{\"first_sign_in_method\":\"anonymous\",\"first_sign_in\":\"2024-10-15T19:46:13.985Z\",\"modified\":\"2024-10-15T19:46:13.141Z\",\"last_sign_in\":\"2024-10-15T19:46:13.985Z\",\"app_variants\":{\"base\":{\"last_sign_in_method\":\"anonymous\",\"last_sign_in\":\"2024-10-15T19:46:13.985Z\"}},\"auth_level\":\"guest\",\"last_sign_in_method\":\"anonymous\",\"created\":\"2024-10-15T19:46:13.141Z\",\"last_active\":\"2024-10-15T19:46:13.985Z\",\"verified_date\":\"2024-10-15T19:46:13.985Z\"}}
    """

    func testDecodingUserWithDataWithoutIsLoading() {
        do {
            let decoder = JSONDecoder()
            let userState = try decoder.decode(
                UserState.self,
                from: (userStringWithDataAndWithoutIsLoading.data(using: .utf8) ?? Data())
            )
            
            XCTAssertTrue(userState.isLoading == false)
            XCTAssertTrue(userState.data["user_id"] == "user_totlsniyvtakfd1y1cad6zpe")
            
        } catch {
            XCTFail("Failed to decode user string \(error)")
        }
        
    }
    
}
