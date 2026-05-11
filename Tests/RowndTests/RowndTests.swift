//
//  RowndTests.swift
//  RowndTests
//
//  Created by Matt Hamann on 7/15/22.
//

import Testing
@testable import Rownd
import Foundation

@Suite(.serialized) struct RowndTests {

    init() async throws {

    }

    @Test func signOut() async throws {
        let originalContext = Context.currentContext
        let isolatedStore = createStore()
        _ = Context(isolatedStore)
        defer {
            Context.currentContext = originalContext
        }

        let store = Context.currentContext.store

        await MainActor.run {
            store.dispatch(SetAuthState(payload: AuthState(
                accessToken: generateJwt(expires: NSDate().timeIntervalSince1970),
                refreshToken: generateJwt(expires: NSDate().timeIntervalSince1970)
            )))
        }

        #expect(store.state?.auth.isAuthenticated == true)

        Rownd.signOut()

        // Rownd.signOut() schedules the auth-state clear on the main actor, so
        // poll for a short, bounded window until the async state update lands.
        for _ in 0..<20 {
            let isAuthenticated = await MainActor.run {
                store.state?.auth.isAuthenticated
            }

            if isAuthenticated == false {
                break
            }

            try await Task.sleep(nanoseconds: 25_000_000)
        }

        await MainActor.run {
            #expect(store.state?.auth.isAuthenticated == false)
        }
    }

}
