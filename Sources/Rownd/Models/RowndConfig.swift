//
//  RowndConfig.swift
//  ios native
//
//  Created by Matt Hamann on 6/14/22.
//

import Foundation

public struct RowndSuperTokensConfig: Encodable, Hashable {
    public var appName: String
    public var apiDomain: String
    public var apiBasePath: String

    public init(appName: String, apiDomain: String, apiBasePath: String = "/auth") {
        self.appName = appName
        self.apiDomain = apiDomain
        self.apiBasePath = apiBasePath
    }
}

public struct RowndConfig: Encodable {
    internal init() {}

    private enum SuperTokensConfigState {
        case missing
        case configured(RowndSuperTokensConfig)
    }

    // These are encoded for the hub to read
    public var apiUrl = ""
    public var baseUrl = "https://rownd-hub.supertokens.com"
    public var subdomainExtension = ".rownd.link"
    public var appKey = ""
    public var deepLinkScheme = "rowndsupertokens"
    public var forceDarkMode = false
    public var postSignInRedirect: String? = "NATIVE_APP"
    public var googleClientId: String = ""
    public var customizations: RowndCustomizations = RowndCustomizations()

    // These will not be encoded
    public var enableDebugMode: Bool = false
    public var appGroupPrefix: String?
    public var enableSmartLinkPasteBehavior: Bool = true
    public var signInLinkPattern: String = ".*\\.rownd\\.link$"
    public var deepLinkHandler: RowndDeepLinkHandlerDelegate?
    public var forceInstantUserConversion: Bool = false
    internal var pendingHubDeepLinkUrl: URL?
    private var superTokensConfigState: SuperTokensConfigState = .missing

    public var supertokens: RowndSuperTokensConfig {
        get {
            switch superTokensConfigState {
            case .missing:
                fatalError("SuperTokens configuration is required")
            case let .configured(supertokens):
                return supertokens
            }
        }
        set {
            superTokensConfigState = .configured(newValue)
        }
    }

    internal func requireSuperTokensConfig() throws -> RowndSuperTokensConfig {
        switch superTokensConfigState {
        case .missing:
            throw RowndError("SuperTokens configuration is required")
        case let .configured(supertokens):
            return supertokens
        }
    }

    private enum CodingKeys: String, CodingKey {
        case apiUrl,
             baseUrl,
              subdomainExtension,
              appKey,
              deepLinkScheme,
              forceDarkMode,
             postSignInRedirect,
             googleClientId,
             customizations,
             supertokens
    }

    private struct HubSuperTokensConfig: Encodable {
        let appInfo: HubSuperTokensAppInfo
    }

    private struct HubSuperTokensAppInfo: Encodable {
        let apiDomain: String
        let apiBasePath: String
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(apiUrl, forKey: .apiUrl)
        try container.encode(baseUrl, forKey: .baseUrl)
        try container.encode(subdomainExtension, forKey: .subdomainExtension)
        try container.encode(appKey, forKey: .appKey)
        try container.encode(deepLinkScheme, forKey: .deepLinkScheme)
        try container.encode(forceDarkMode, forKey: .forceDarkMode)
        try container.encodeIfPresent(postSignInRedirect, forKey: .postSignInRedirect)
        try container.encode(googleClientId, forKey: .googleClientId)
        try container.encode(customizations, forKey: .customizations)

        let supertokens = try requireSuperTokensConfig()
        try container.encode(
            HubSuperTokensConfig(
                appInfo: HubSuperTokensAppInfo(
                    apiDomain: supertokens.apiDomain,
                    apiBasePath: supertokens.apiBasePath
                )
            ),
            forKey: .supertokens
        )
    }

    func toJson() -> String {
        let encoder = JSONEncoder()
        encoder.dataEncodingStrategy = .base64

        do {
            let encodedData = try encoder.encode(self)
            return String(data: encodedData, encoding: .utf8) ?? "{}"
        } catch {
            fatalError("Couldn't encode Rownd Config as \(self):\n\(error)")
        }
    }

    internal mutating func consumePendingHubDeepLinkUrl() -> URL? {
        let url = pendingHubDeepLinkUrl
        pendingHubDeepLinkUrl = nil
        return url
    }
}
