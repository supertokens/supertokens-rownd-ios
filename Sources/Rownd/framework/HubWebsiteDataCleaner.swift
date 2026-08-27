import Foundation
import WebKit

internal enum HubWebsiteDataCleaner {
    private static let managedParentDomains = [
        "rownd-hub.supertokens.com",
        "supertokens.com",
    ]

    @MainActor
    static func clear(for hubBaseURL: String) async throws {
        try await clear(for: hubBaseURL, dataStore: .default())
    }

    @MainActor
    static func clear(for hubBaseURL: String, dataStore: WKWebsiteDataStore) async throws {
        guard let host = URL(string: hubBaseURL)?.host else {
            throw RowndError("Could not clear Hub website data because the Hub URL is invalid")
        }

        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                continuation.resume(returning: records)
            }
        }
        let hubRecords = records.filter { recordDisplayName($0.displayName, matchesHost: host) }
        guard !hubRecords.isEmpty else { return }

        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: dataTypes, for: hubRecords) {
                continuation.resume()
            }
        }
    }

    static func recordDisplayName(_ displayName: String, matchesHost host: String) -> Bool {
        let displayName = normalizeHost(displayName)
        let host = normalizeHost(host)
        guard !displayName.isEmpty, !host.isEmpty else { return false }

        guard displayName != host else { return true }
        return managedParentDomains.contains(displayName)
            && host.hasSuffix(".\(displayName)")
    }

    private static func normalizeHost(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
