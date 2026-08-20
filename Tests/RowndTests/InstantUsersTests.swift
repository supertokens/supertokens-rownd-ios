//
//  InstantUsersTests.swift
//  RowndTests
//
//  Tests for InstantUsers lifecycle and conversion prompt behavior.
//

import Foundation
import ReSwift
import XCTest

@testable import Rownd

@MainActor
class InstantUsersTests: XCTestCase {
    func testSubscriptionSurvivesWhenInstantUsersIsRetained() throws {
        try withInstantUsersTest(forceConversion: true) { store, instantUsers, recorder in
            instantUsers.tmpForceInstantUserConversionIfRequested()
            dispatchUserState(store: store, authLevel: .instant)
            wait(for: [recorder.signInRequested], timeout: 1.0)

            XCTAssertEqual(recorder.options.count, 1)
            XCTAssertEqual(recorder.options.first?.intent, .signUp)
        }
    }

    /// Verifies that the subscription does not fire for non-instant users.
    func testSubscriptionDoesNotFireForVerifiedUsers() throws {
        try withInstantUsersTest(forceConversion: true) { store, instantUsers, recorder in
            instantUsers.tmpForceInstantUserConversionIfRequested()
            dispatchUserState(store: store, authLevel: .verified)
            recorder.signInRequested.isInverted = true
            wait(for: [recorder.signInRequested], timeout: 0.1)

            XCTAssertTrue(recorder.options.isEmpty)
        }
    }

    /// Verifies that tmpForceInstantUserConversionIfRequested is a no-op when
    /// forceInstantUserConversion is false — no subscriptions should be created.
    func testNoOpWhenForceConversionDisabled() throws {
        try withInstantUsersTest(forceConversion: false) { store, instantUsers, recorder in
            instantUsers.tmpForceInstantUserConversionIfRequested()
            dispatchUserState(store: store, authLevel: .instant)
            recorder.signInRequested.isInverted = true
            wait(for: [recorder.signInRequested], timeout: 0.1)

            XCTAssertTrue(recorder.options.isEmpty)
        }
    }

    /// Verifies that the subscription fires immediately when cached state already
    /// satisfies the condition (isAuthenticated && authLevel == .instant) at
    /// subscription time.
    func testSubscriptionFiresImmediatelyForCachedInstantUser() throws {
        try withInstantUsersTest(forceConversion: true) { store, instantUsers, recorder in
            dispatchUserState(store: store, authLevel: .instant)
            instantUsers.tmpForceInstantUserConversionIfRequested()
            wait(for: [recorder.signInRequested], timeout: 1.0)

            XCTAssertEqual(recorder.options.count, 1)
        }
    }

    func testSubscriptionDoesNotRetainInstantUsers() {
        let originalConfig = Rownd.config
        let originalContext = Context.currentContext
        defer {
            Rownd.config = originalConfig
            Context.currentContext = originalContext
        }

        let context = Context(createStore())
        Rownd.config.forceInstantUserConversion = true
        weak var retainedInstantUsers: InstantUsers?
        var instantUsers: InstantUsers? = InstantUsers(context: context) { _ in }
        retainedInstantUsers = instantUsers

        instantUsers?.tmpForceInstantUserConversionIfRequested()
        instantUsers = nil

        XCTAssertNil(retainedInstantUsers)
    }

    private func withInstantUsersTest(
        forceConversion: Bool,
        operation: (Store<RowndState>, InstantUsers, SignInRecorder) throws -> Void
    ) throws {
        let originalConfig = Rownd.config
        let originalContext = Context.currentContext
        defer {
            Rownd.config = originalConfig
            Context.currentContext = originalContext
        }

        let store = createStore()
        let context = Context(store)
        let recorder = SignInRecorder()
        Rownd.config.forceInstantUserConversion = forceConversion
        let instantUsers = InstantUsers(context: context) { options in
            recorder.record(options)
        }

        try operation(store, instantUsers, recorder)
    }

    private func dispatchUserState(store: Store<RowndState>, authLevel: UserAuthLevel) {
        store.dispatch(SetAuthState(payload: AuthState(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date(timeIntervalSinceNow: 36000).timeIntervalSince1970)
        )))
        store.dispatch(SetClockSync(clockSyncState: .synced))
        store.dispatch(SetUserState(payload: UserState(
            data: ["user_id": "test_user"],
            authLevel: authLevel
        )))
    }
}

@MainActor
private final class SignInRecorder {
    let signInRequested = XCTestExpectation(description: "Sign-in requested")
    private(set) var options: [RowndSignInOptions] = []

    func record(_ options: RowndSignInOptions) {
        self.options.append(options)
        signInRequested.fulfill()
    }
}
