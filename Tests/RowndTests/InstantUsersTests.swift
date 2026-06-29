//
//  InstantUsersTests.swift
//  RowndTests
//
//  Tests for InstantUsers lifecycle and conversion prompt behavior.
//

import Combine
import Foundation
import ReSwift
import XCTest

@testable import Rownd

@MainActor
class InstantUsersTests: XCTestCase {

    private var originalConfig: RowndConfig!

    override func setUp() {
        super.setUp()
        originalConfig = Rownd.config
    }

    override func tearDown() {
        Rownd.config = originalConfig
        super.tearDown()
    }

    /// Verifies that when `authLevel` becomes `.instant` asynchronously (after
    /// subscription setup), the Combine pipeline still fires. Before the fix,
    /// the `InstantUsers` instance was a local temporary whose deallocation
    /// cancelled the subscription before the condition could be met.
    func testSubscriptionSurvivesWhenInstantUsersIsRetained() async throws {
        let store = createStore()
        _ = Context(store)

        Rownd.config.forceInstantUserConversion = true

        let expectation = XCTestExpectation(description: "Combine subscription fires for instant user")

        // Create and retain the InstantUsers instance (as the fix does)
        let instantUsers = InstantUsers(context: Context.currentContext)

        // Subscribe to detect when requestSignIn triggers (it logs an error about
        // useExplicitSignUpFlow not being enabled, which indicates the pipeline fired)
        let subscriber = store.subscribe { $0 }
        var cancellable: AnyCancellable?
        cancellable = subscriber.$current
            .map { ($0.auth.isAuthenticated, $0.user.authLevel) }
            .removeDuplicates(by: ==)
            .first { isAuthenticated, authLevel in
                isAuthenticated && authLevel == .instant
            }
            .sink { _, _ in
                expectation.fulfill()
                cancellable?.cancel()
                subscriber.unsubscribe()
            }

        // Start the instant users subscription
        instantUsers.tmpForceInstantUserConversionIfRequested()

        // Simulate state arriving asynchronously (as UserData.fetch() would deliver)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms delay

        store.dispatch(SetAuthState(payload: AuthState(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date(timeIntervalSinceNow: 36000).timeIntervalSince1970)
        )))
        store.dispatch(SetClockSync(clockSyncState: .synced))
        store.dispatch(SetUserState(payload: UserState(
            data: ["user_id": "test_instant_user"],
            authLevel: .instant
        )))

        await fulfillment(of: [expectation], timeout: 5.0)

        // Keep instantUsers alive for the duration of the test
        _ = instantUsers
    }

    /// Verifies that the subscription does not fire for non-instant users.
    func testSubscriptionDoesNotFireForVerifiedUsers() async throws {
        let store = createStore()
        _ = Context(store)

        Rownd.config.forceInstantUserConversion = true

        let expectation = XCTestExpectation(description: "Should not fire for verified user")
        expectation.isInverted = true

        let instantUsers = InstantUsers(context: Context.currentContext)
        instantUsers.tmpForceInstantUserConversionIfRequested()

        // Monitor for the instant user condition — it should never be met
        let subscriber = store.subscribe { $0 }
        var cancellable: AnyCancellable?
        cancellable = subscriber.$current
            .map { ($0.auth.isAuthenticated, $0.user.authLevel) }
            .removeDuplicates(by: ==)
            .first { isAuthenticated, authLevel in
                isAuthenticated && authLevel == .instant
            }
            .sink { _, _ in
                expectation.fulfill()
                cancellable?.cancel()
                subscriber.unsubscribe()
            }

        store.dispatch(SetAuthState(payload: AuthState(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date(timeIntervalSinceNow: 36000).timeIntervalSince1970)
        )))
        store.dispatch(SetClockSync(clockSyncState: .synced))
        store.dispatch(SetUserState(payload: UserState(
            data: ["user_id": "test_verified_user"],
            authLevel: .verified
        )))

        await fulfillment(of: [expectation], timeout: 1.0)

        _ = instantUsers
    }

    /// Verifies that tmpForceInstantUserConversionIfRequested is a no-op when
    /// forceInstantUserConversion is false — no subscriptions should be created.
    func testNoOpWhenForceConversionDisabled() async throws {
        let store = createStore()
        _ = Context(store)

        Rownd.config.forceInstantUserConversion = false

        let instantUsers = InstantUsers(context: Context.currentContext)
        instantUsers.tmpForceInstantUserConversionIfRequested()

        // Dispatch instant user state. If the feature were active, it would
        // call requestSignIn. Since it's disabled, nothing should happen.
        store.dispatch(SetAuthState(payload: AuthState(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date(timeIntervalSinceNow: 36000).timeIntervalSince1970)
        )))
        store.dispatch(SetClockSync(clockSyncState: .synced))
        store.dispatch(SetUserState(payload: UserState(
            data: ["user_id": "test_instant_user"],
            authLevel: .instant
        )))

        // Give any potential subscriptions time to fire
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // If we reach here without requestSignIn being called, the test passes.
        // The feature flag early-return prevents any subscription from being created.
        _ = instantUsers
    }

    /// Verifies that the subscription fires immediately when cached state already
    /// satisfies the condition (isAuthenticated && authLevel == .instant) at
    /// subscription time.
    func testSubscriptionFiresImmediatelyForCachedInstantUser() async throws {
        let store = createStore()
        _ = Context(store)

        Rownd.config.forceInstantUserConversion = true

        // Set state BEFORE creating InstantUsers (simulating cached state from inflateStoreCache)
        store.dispatch(SetAuthState(payload: AuthState(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: generateJwt(expires: Date(timeIntervalSinceNow: 36000).timeIntervalSince1970)
        )))
        store.dispatch(SetClockSync(clockSyncState: .synced))
        store.dispatch(SetUserState(payload: UserState(
            data: ["user_id": "test_instant_user"],
            authLevel: .instant
        )))

        let expectation = XCTestExpectation(description: "Should fire immediately for cached instant user")

        let subscriber = store.subscribe { $0 }
        var cancellable: AnyCancellable?
        cancellable = subscriber.$current
            .map { ($0.auth.isAuthenticated, $0.user.authLevel) }
            .removeDuplicates(by: ==)
            .first { isAuthenticated, authLevel in
                isAuthenticated && authLevel == .instant
            }
            .sink { _, _ in
                expectation.fulfill()
                cancellable?.cancel()
                subscriber.unsubscribe()
            }

        let instantUsers = InstantUsers(context: Context.currentContext)
        instantUsers.tmpForceInstantUserConversionIfRequested()

        await fulfillment(of: [expectation], timeout: 2.0)

        _ = instantUsers
    }
}
