import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct UserProfileFetchCoordinatorTests {
    @Test func accountABAInvalidatesEveryOlderRequestIdentity() throws {
        let coordinator = UserProfileFetchCoordinator()
        let firstA = try #require(coordinator.begin(accessToken: "account-a", purpose: .foreground))
        let accountB = try #require(coordinator.begin(accessToken: "account-b", purpose: .foreground))
        let secondA = try #require(coordinator.begin(accessToken: "account-a", purpose: .foreground))

        #expect(!coordinator.isCurrent(firstA))
        #expect(!coordinator.isCurrent(accountB))
        #expect(coordinator.isCurrent(secondA))

        coordinator.finish(firstA)
        #expect(coordinator.isCurrent(secondA))
    }

    @Test func foregroundFetchDoesNotRaceSameSessionOrReplacementFetch() throws {
        let coordinator = UserProfileFetchCoordinator()
        let foreground = try #require(coordinator.begin(
            accessToken: "replacement-session",
            purpose: .foreground
        ))
        #expect(coordinator.begin(
            accessToken: "replacement-session",
            purpose: .foreground
        ) == nil)

        let replacement = try #require(coordinator.begin(
            accessToken: "replacement-session",
            purpose: .replacement
        ))
        #expect(!coordinator.isCurrent(foreground))
        #expect(coordinator.isCurrent(replacement))
        #expect(coordinator.begin(
            accessToken: "replacement-session",
            purpose: .foreground
        ) == nil)
    }

    @Test func suspendedForegroundAIsSupersededByReplacementBButForegroundCCannotSupersedeIt() throws {
        let coordinator = UserProfileFetchCoordinator()
        let foregroundA = try #require(coordinator.begin(
            accessToken: "account-a",
            purpose: .foreground
        ))
        let replacementB = try #require(coordinator.begin(
            accessToken: "account-b",
            purpose: .replacement
        ))

        #expect(!coordinator.isCurrent(foregroundA))
        #expect(coordinator.isCurrent(replacementB))
        #expect(coordinator.begin(
            accessToken: "account-c",
            purpose: .foreground
        ) == nil)
        #expect(coordinator.isCurrent(replacementB))
    }

    @Test func appleEnrichmentSupersedesForegroundButCannotSupersedeReplacement() throws {
        let coordinator = UserProfileFetchCoordinator()
        let foreground = try #require(coordinator.begin(
            accessToken: "apple-session",
            purpose: .foreground
        ))
        let enrichment = try #require(coordinator.begin(
            accessToken: "apple-session",
            purpose: .enrichment
        ))

        #expect(!coordinator.isCurrent(foreground))
        #expect(coordinator.isCurrent(enrichment))

        let replacement = try #require(coordinator.begin(
            accessToken: "replacement-session",
            purpose: .replacement
        ))
        #expect(!coordinator.isCurrent(enrichment))
        #expect(coordinator.begin(
            accessToken: "apple-session",
            purpose: .enrichment
        ) == nil)
        #expect(coordinator.isCurrent(replacement))
    }

    @Test func staleFetchCompletionCannotClearNewerLoadingOperation() {
        let firstOperationID = UUID()
        let secondOperationID = UUID()
        var state = userReducer(
            action: SetUserFetchLoading(operationId: firstOperationID, isLoading: true),
            state: nil
        )
        state = userReducer(
            action: SetUserFetchLoading(operationId: secondOperationID, isLoading: true),
            state: state
        )
        state = userReducer(
            action: SetUserFetchLoading(operationId: firstOperationID, isLoading: false),
            state: state
        )

        #expect(state.isLoading)
        #expect(state.activeFetchOperations == Set([secondOperationID]))

        state = userReducer(
            action: SetUserFetchLoading(operationId: secondOperationID, isLoading: false),
            state: state
        )
        #expect(!state.isLoading)
    }
}
