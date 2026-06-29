import Combine
import Foundation
import ReSwift
import Testing

@testable import Rownd

@MainActor
struct SubscriberMutationTests {
    @Test
    func rapidClockSyncAndObserverChurnDoesNotCrash() async throws {
        let store = Context.currentContext.store

        // Ensure starting state
        _ = await store.state.load(store)

        let iterations = 50

        // Flip clockSyncState quickly on main
        let flipTask = Task { @MainActor in
            for i in 0..<iterations {
                let state: ClockSyncState = (i % 2 == 0) ? .waiting : .synced
                store.dispatch(SetClockSync(clockSyncState: state))
            }
        }

        // Create and drop observable subscribers rapidly (subscribe/unsubscribe)
        for _ in 0..<iterations {
            autoreleasepool {
                let obs = store.subscribe { $0.clockSyncState }
                _ = obs  // keep alive within loop scope
            }
        }

        _ = await flipTask.value
        // If we reached here without a crash, we consider it a pass.
    }
}
