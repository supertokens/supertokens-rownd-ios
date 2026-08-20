//
//  Helpers.swift
//  RowndTests
//
//  Created by Matt Hamann on 11/10/22.
//

import Foundation
import Get
import Mocker

extension APIClient {
    static func mock(_ configure: (inout APIClient.Configuration) -> Void = { _ in }) -> APIClient {
        APIClient(baseURL: URL(string: "https://api.rownd.io")) {
            $0.sessionConfiguration.protocolClasses = [MockingURLProtocol.self]
            $0.sessionConfiguration.urlCache = nil
            configure(&$0)
        }
    }
}

private final class GlobalTestLock: @unchecked Sendable {
    static let shared = GlobalTestLock()

    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [Waiter] = []

    private enum Waiter {
        case asynchronous(CheckedContinuation<Void, Never>)
        case synchronous(DispatchSemaphore)
    }

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isLocked {
                waiters.append(.asynchronous(continuation))
                lock.unlock()
                return
            }

            isLocked = true
            lock.unlock()
            continuation.resume()
        }
    }

    func acquireSynchronously() {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        if isLocked {
            waiters.append(.synchronous(semaphore))
            lock.unlock()
            semaphore.wait()
            return
        }

        isLocked = true
        lock.unlock()
    }

    func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            isLocked = false
            lock.unlock()
            return
        }

        let waiter = waiters.removeFirst()
        lock.unlock()

        switch waiter {
        case .asynchronous(let continuation):
            continuation.resume()
        case .synchronous(let semaphore):
            semaphore.signal()
        }
    }
}

func withGlobalTestLock<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    await GlobalTestLock.shared.acquire()
    do {
        let result = try await operation()
        GlobalTestLock.shared.release()
        return result
    } catch {
        GlobalTestLock.shared.release()
        throw error
    }
}

func withSynchronousGlobalTestLock<T>(_ operation: () throws -> T) throws -> T {
    GlobalTestLock.shared.acquireSynchronously()
    defer {
        GlobalTestLock.shared.release()
    }
    return try operation()
}
