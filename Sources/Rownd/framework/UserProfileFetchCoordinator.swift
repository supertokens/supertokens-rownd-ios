import Foundation

internal final class UserProfileFetchCoordinator: @unchecked Sendable {
    enum Purpose: Equatable {
        case foreground
        case enrichment
        case replacement
    }

    struct Ticket: Equatable {
        let id: UUID
        let accessToken: String
        let purpose: Purpose
    }

    private let lock = NSLock()
    private var activeTicket: Ticket?

    func begin(accessToken: String, purpose: Purpose) -> Ticket? {
        lock.lock()
        defer { lock.unlock() }

        if let activeTicket {
            if activeTicket.purpose == .replacement && purpose != .replacement {
                return nil
            }
            if purpose == .foreground,
               activeTicket.purpose != .foreground || activeTicket.accessToken == accessToken {
                return nil
            }
            if purpose == .enrichment,
               activeTicket.purpose == .enrichment,
               activeTicket.accessToken == accessToken {
                return nil
            }
        }

        let ticket = Ticket(id: UUID(), accessToken: accessToken, purpose: purpose)
        activeTicket = ticket
        return ticket
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeTicket == ticket
    }

    func finish(_ ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        guard activeTicket == ticket else { return }
        activeTicket = nil
    }

    func cancel(_ ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        guard activeTicket == ticket else { return }
        activeTicket = nil
    }

    func cancelCurrent() {
        lock.lock()
        activeTicket = nil
        lock.unlock()
    }
}
