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

private enum GlobalTestLock {
    static let queue = DispatchQueue(label: "io.rownd.tests.global-lock")
}

private final class AsyncResultBox<T>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func succeed(_ value: T) {
        finish(.success(value))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> T {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}

func withGlobalTestLock<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) {
        try GlobalTestLock.queue.sync {
            let box = AsyncResultBox<T>()

            Task {
                do {
                    box.succeed(try await operation())
                } catch {
                    box.fail(error)
                }
            }

            return try box.wait()
        }
    }.value
}
