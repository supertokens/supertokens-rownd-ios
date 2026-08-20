import Foundation
import Get
import OSLog
import ReSwift

// Data structure for the World Time API response
struct WorldTimeResponse: Codable {
    let utcDateTime: String

    enum CodingKeys: String, CodingKey {
        case utcDateTime = "utc_datetime"
    }
}

class NetworkTimeManager {
    internal static let shared = NetworkTimeManager()

    private let log = Logger(subsystem: "io.rownd.sdk", category: "TimeManager")
    private let startLock = NSLock()
    private let stateLock = NSLock()
    private var didStart = false
    private var fetchTimeTask: Task<Bool, Never>?
    private var fetchedWorldTime: Date?
    private var fetchTime: Date?

    internal var currentTime: Date? {
        get {
            let (fetchedWorldTime, fetchTime) = stateLock.withLock {
                (self.fetchedWorldTime, self.fetchTime)
            }
            guard let fetchedWorldTime = fetchedWorldTime, let fetchTime = fetchTime else {
                log.warning("Network time not available.")
                return nil
            }

            // Calculate the time passed since the world time was fetched
            let timePassed = Date().timeIntervalSince(fetchTime)

            // Add the time passed to the fetched world time to get the current world time
            return fetchedWorldTime.addingTimeInterval(timePassed)
        }
    }

    let client = APIClient(baseURL: URL(string: "https://time.rownd.io"))

    // Starts process-wide synchronization once. The first store receives clock state updates.
    func start(store: Store<RowndState>) {
        let shouldStart = startLock.withLock {
            guard !didStart else {
                return false
            }
            didStart = true
            return true
        }
        guard shouldStart else {
            return
        }

        let ntpStart = Date()
        Task {
            guard await fetchWorldTime() else {
                return
            }

            await MainActor.run {
                if store.state.clockSyncState != .synced {
                    store.dispatch(SetClockSync(clockSyncState: .synced))
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if store.state.clockSyncState == .waiting {
                self.log.warning("TimeManager clock not synced after \(ntpStart.distance(to: Date())) seconds.")
                store.dispatch(SetClockSync(clockSyncState: .unknown))
            }
        }
    }

    // Fetch the current world time and store the initial reference
    func fetchWorldTime() async -> Bool {
        let task = Task { () -> Bool in
            defer {
                stateLock.withLock {
                    fetchTimeTask = nil
                }
            }

            do {
                let response: WorldTimeResponse = try await client.send(Request(path: "/now")).value

                // Custom date formatter to handle the response from world time
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX" // Supports microseconds and time zone
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)

                guard let fetchedDate = formatter.date(from: response.utcDateTime) else {
                    log.warning("Error parsing network time")
                    return false
                }

                stateLock.withLock {
                    self.fetchedWorldTime = fetchedDate
                    self.fetchTime = Date()
                }
                return true
            } catch {
                log.warning("Error fetching network time: \(error)")
                return false
            }
        }

        stateLock.withLock {
            fetchTimeTask = task
        }

        return await task.value
    }

    // Get the current world time without re-fetching
    func getCurrentWorldTime() async -> Date {
        let pendingTask: Task<Bool, Never>? = stateLock.withLock {
            self.fetchTimeTask
        }
        if let pendingTask = pendingTask {
            _ = await pendingTask.value
        }

        if currentTime == nil {
            _ = await fetchWorldTime()
        }

        guard let currentTime = currentTime else {
            log.warning("Network time not found. Using local time instead")
            return Date()
        }
        return currentTime
    }
}
