//
//  ObservableStateTests.swift
//  RowndTests
//
//  Tests for thread safety and memory management in ObservableState classes.
//  These tests reproduce crashes that occurred when newState was called from
//  background threads or when observers were deallocated during state updates.
//

import Combine
import Foundation
import ReSwift
import Testing

@testable import Rownd

@MainActor
struct ObservableStateTests {

    /// Tests that ObservableState can handle newState being called from background threads.
    /// Pre-fix, this would crash in swift_retain when accessing the @Published property
    /// from a non-main thread.
    @Test
    func observableStateHandlesBackgroundThreadStateUpdates() async throws {
        let store = createStore()
        _ = Context(store)

        // Create an observable state
        let observer = store.subscribe { $0.clockSyncState }

        let iterations = 100

        // Dispatch state changes from background threads - this is what ReSwift might do
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let state: ClockSyncState = (i % 2 == 0) ? .waiting : .synced
                    // Simulate ReSwift calling newState from a background thread
                    observer.newState(state: state)
                }
            }
        }

        // If we reach here without crashing, the test passes
        _ = observer
    }

    /// Tests that ObservableThrottledState can handle newState from background threads.
    /// Pre-fix, this crashed because it accessed self.current outside the main queue dispatch.
    @Test
    func observableThrottledStateHandlesBackgroundThreadStateUpdates() async throws {
        let store = createStore()
        _ = Context(store)

        // Create a throttled observable state
        let observer = store.subscribeThrottled(select: { $0.clockSyncState }, throttleInMs: 50)

        let iterations = 100

        // Dispatch state changes from background threads
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let state: ClockSyncState = (i % 2 == 0) ? .waiting : .synced
                    // Simulate ReSwift calling newState from a background thread
                    observer.newState(state: state)
                }
            }
        }

        // If we reach here without crashing, the test passes
        _ = observer
    }

    /// Tests that ObservableDerivedState can handle newState from background threads.
    /// Pre-fix, this crashed due to missing [weak self] in the async block.
    @Test
    func observableDerivedStateHandlesBackgroundThreadStateUpdates() async throws {
        let store = createStore()
        _ = Context(store)

        // Create a derived observable state
        let observer = store.subscribe(
            select: { $0.clockSyncState },
            transform: { state -> String in
                switch state {
                case .waiting: return "waiting"
                case .synced: return "synced"
                case .unknown: return "unknown"
                case .failed: return "failed"
                }
            }
        )

        let iterations = 100

        // Dispatch state changes from background threads
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let state: ClockSyncState = (i % 2 == 0) ? .waiting : .synced
                    // Simulate ReSwift calling newState from a background thread
                    observer.newState(state: state)
                }
            }
        }

        // If we reach here without crashing, the test passes
        _ = observer
    }

    /// Tests that ObservableDerivedThrottledState can handle newState from background threads.
    /// Pre-fix, this crashed because it accessed current outside main dispatch and lacked [weak self].
    @Test
    func observableDerivedThrottledStateHandlesBackgroundThreadStateUpdates() async throws {
        let store = createStore()
        _ = Context(store)

        // Create a derived throttled observable state
        let observer = store.subscribeThrottled(
            select: { $0.clockSyncState },
            transform: { state -> String in
                switch state {
                case .waiting: return "waiting"
                case .synced: return "synced"
                case .unknown: return "unknown"
                case .failed:
                    return "failed"
                }
            },
            throttleInMs: 50
        )

        let iterations = 100

        // Dispatch state changes from background threads
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let state: ClockSyncState = (i % 2 == 0) ? .waiting : .synced
                    // Simulate ReSwift calling newState from a background thread
                    observer.newState(state: state)
                }
            }
        }

        // If we reach here without crashing, the test passes
        _ = observer
    }

    /// Tests that rapidly creating and destroying observers while dispatching state
    /// does not crash. Pre-fix, missing [weak self] could cause crashes when the
    /// async block executed after the observer was deallocated.
    @Test
    func rapidObserverCreationAndDestructionDoesNotCrash() async throws {
        let store = createStore()
        _ = Context(store)

        let iterations = 50

        // Dispatch state changes on main thread
        let dispatchTask = Task { @MainActor in
            for i in 0..<iterations {
                let state: ClockSyncState = (i % 2 == 0) ? .waiting : .synced
                store.dispatch(SetClockSync(clockSyncState: state))
            }
        }

        // Rapidly create and destroy observers
        // The [weak self] fix ensures we don't crash when the async block runs
        // after the observer is deallocated
        for _ in 0..<iterations {
            autoreleasepool {
                let obs1 = store.subscribe { $0.clockSyncState }
                let obs2 = store.subscribeThrottled(select: { $0.clockSyncState }, throttleInMs: 10)
                let obs3 = store.subscribe(
                    select: { $0.clockSyncState },
                    transform: { "\($0)" }
                )
                // Let them get deallocated immediately
                _ = (obs1, obs2, obs3)
            }
        }

        _ = await dispatchTask.value

        // Give time for any pending async blocks to execute
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // If we reach here without crashing, the test passes
    }

    /// Tests concurrent newState calls from multiple background threads while
    /// the observer is being deallocated. This is the most aggressive test case
    /// that reproduces the exact crash scenario from the bug reports.
    @Test
    func concurrentNewStateCallsDuringDeallocationDoesNotCrash() async throws {
        let store = createStore()
        _ = Context(store)

        let iterations = 30

        for _ in 0..<iterations {
            // Create observer in an autoreleasepool so it gets deallocated quickly
            await withCheckedContinuation { continuation in
                autoreleasepool {
                    let observer = store.subscribeThrottled(select: { $0.clockSyncState }, throttleInMs: 5)

                    // Fire off background thread state updates
                    DispatchQueue.global(qos: .userInteractive).async {
                        observer.newState(state: .waiting)
                    }
                    DispatchQueue.global(qos: .default).async {
                        observer.newState(state: .synced)
                    }
                    DispatchQueue.global(qos: .utility).async {
                        observer.newState(state: .waiting)
                    }

                    // Observer will be deallocated when autoreleasepool exits
                    // Pre-fix, the async blocks in newState could crash when they execute
                    // because they didn't use [weak self]
                }

                // Small delay to let async blocks execute
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    continuation.resume()
                }
            }
        }

        // If we reach here without crashing, the test passes
    }
}
