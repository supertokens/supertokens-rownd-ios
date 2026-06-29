//
//  File.swift
//  
//
//  Created by Matt Hamann on 10/4/24.
//

import Foundation
import OSLog

@available(iOS 15.0, *)
func fetchRecentLogs(secondsBack: TimeInterval) {
    do {
        // 1. Create an OSLogStore for the current process
        let logStore = try OSLogStore(scope: .currentProcessIdentifier)

        // 2. Define the time range: current time minus 'secondsBack'
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-secondsBack)

        // 3. Retrieve the position of logs for the starting point
        let position = logStore.position(date: startDate)

        // Set predicate to match against
        let predicate = NSPredicate(format: "subsystem == %@", "io.rownd.sdk")

        // 4. Create an entry iterator starting from the specified position
        let entries = try logStore.getEntries(at: position, matching: predicate)

        // 5. Iterate over the entries and log the messages
        for case let entry as OSLogEntryLog in entries {
            logger.debug("Timestamp: \(entry.date), Subsystem: \(entry.subsystem), Category: \(entry.category), Message: \(entry.composedMessage)")
        }

    } catch {
        logger.warning("Failed to fetch logs: \(String(describing: error))")
    }
}

class LogCapture {
    private var maxEntries: Int
    private var entries: [String] = []

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func push(_ entry: String) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst()
        }
    }

    func getEntries() -> [String] {
        return entries
    }
}
