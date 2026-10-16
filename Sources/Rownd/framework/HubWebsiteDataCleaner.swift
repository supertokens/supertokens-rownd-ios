import Foundation
import WebKit

internal enum HubWebsiteDataCleaner {
    @MainActor static func clearAuthentication(hubURL: String, apiURL: String,
                                               dataStore: WKWebsiteDataStore? = nil) async throws {
        let dataStore = dataStore ?? .default()
        let hosts = try [hubURL, apiURL].map { value -> String in
            guard let host = URL(string: value)?.host else { throw RowndError("Invalid authentication storage origin") }
            return host.lowercased()
        }
        let matches: (String) -> Bool = { domain in
            let domain = normalizeHost(domain)
            return !domain.isEmpty && hosts.contains { $0 == domain || $0.hasSuffix(".\(domain)") }
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        await dataStore.removeData(ofTypes: types, for: records.filter { matches($0.displayName) })
        let cookies = await dataStore.httpCookieStore.allCookies()
        for cookie in cookies where matches(cookie.domain) {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where matches(cookie.domain) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        let remainingCookies = await dataStore.httpCookieStore.allCookies()
        guard !remainingCookies.contains(where: { matches($0.domain) }),
              !(HTTPCookieStorage.shared.cookies ?? []).contains(where: { matches($0.domain) }) else {
            throw RowndError("Authentication cookies could not be cleared")
        }
    }

    private static let managedParentDomains = [
        "rownd-hub.supertokens.com",
        "supertokens.com",
        "rownd-hub.supertokens.io",
        "supertokens.io",
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
