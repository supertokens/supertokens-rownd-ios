//
//  StateTests.swift
//  
//
//  Created by Matt Hamann on 4/1/24.
//

import Foundation
import XCTest
import Combine
import ReSwift

@testable import Rownd

class StateTests: XCTestCase {
    override func setUp() {
        super.setUp()
    }
    
    func testStateInit() async throws {
        let store = createStore()
        XCTAssertFalse(store.state.isStateLoaded)
        await store.state.load(store)
        try await Task.sleep(nanoseconds: 10000)
        XCTAssertTrue(store.state.isStateLoaded)
    }
    
    func testMultiStepInit() async throws {
        let expectation = XCTestExpectation(description: "Wait for state to initialize")
        let context = Context.currentContext
        let store = context.store
        
        let rootSubscriber = TestFilteredSubscriber<RowndState?>()
        let authSubscriber = TestFilteredSubscriber<AuthState?>()
        
        store.subscribe(rootSubscriber) {
            $0.select { $0 }
        }
        
        store.subscribe(authSubscriber) {
            $0.select { $0.auth }
        }
        
        Task { @MainActor in
            await store.state.load(store)
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 3600).timeIntervalSince1970),
                refreshToken: generateJwt(expires: Date.init(timeIntervalSinceNow: 36000).timeIntervalSince1970)
            )))
            store.dispatch(SetClockSync(clockSyncState: .synced))
            try await Task.sleep(nanoseconds: 20000)
            XCTAssertTrue((((rootSubscriber.receivedValue as? RowndState)?.isInitialized) == true))
            XCTAssertTrue((((authSubscriber.receivedValue as? AuthState)?.isAccessTokenValid) == true))
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 10.0)
    }
    
}

class TestFilteredSubscriber<T>: StoreSubscriber {
    var receivedValue: T!
    var newStateCallCount = 0

    func newState(state: T) {
        receivedValue = state
        newStateCallCount += 1
    }

}
