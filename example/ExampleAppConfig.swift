import Foundation

enum ExampleAppConfig {
    private static let defaultApiDomain = "http://127.0.0.1:3137"
    private static let defaultHubBaseUrl = "https://staging.supertokens-rownd-hub.pages.dev"
    private static let defaultAppKey = "test_app_key"
    private static let defaultApiBasePath = "/auth"
    private static let defaultAppGroupPrefix = "group.rowndexample"
    private static let defaultSubdomainExtension = ".rownd-hub.supertokens.com"

    static var apiDomain: String {
        stringValue("ROWND_EXAMPLE_API_DOMAIN", fallback: defaultApiDomain)
    }

    static var hubBaseUrl: String {
        stringValue("ROWND_EXAMPLE_HUB_BASE_URL", fallback: defaultHubBaseUrl)
    }

    static var appKey: String {
        stringValue("ROWND_EXAMPLE_APP_KEY", fallback: defaultAppKey)
    }

    static var apiBasePath: String {
        stringValue("ROWND_EXAMPLE_API_BASE_PATH", fallback: defaultApiBasePath)
    }

    static var appGroupPrefix: String {
        stringValue("ROWND_EXAMPLE_APP_GROUP_PREFIX", fallback: defaultAppGroupPrefix)
    }

    static var subdomainExtension: String {
        stringValue("ROWND_EXAMPLE_SUBDOMAIN_EXTENSION", fallback: defaultSubdomainExtension)
    }

    static var enableDebugMode: Bool {
        boolValue("ROWND_EXAMPLE_ENABLE_DEBUG_MODE", fallback: true)
    }

    static var apiURL: URL {
        URL(string: apiDomain)!
    }

    private static func stringValue(_ key: String, fallback: String) -> String {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, isUsable(value) {
            return value
        }

        if let value = ProcessInfo.processInfo.environment[key], isUsable(value) {
            return value
        }

        return fallback
    }

    private static func boolValue(_ key: String, fallback: Bool) -> Bool {
        let value = stringValue(key, fallback: fallback ? "YES" : "NO").lowercased()
        return ["1", "true", "yes"].contains(value)
    }

    private static func isUsable(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("$(")
    }
}
