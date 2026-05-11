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

    // These are encoded for the hub to read
    public var apiUrl = "https://api.rownd.io"
    public var baseUrl = "https://hub.rownd.io"
    public var subdomainExtension = ".rownd.link"
    public var appKey = ""
    public var forceDarkMode = false
    public var postSignInRedirect: String? = "NATIVE_APP"
    public var googleClientId: String = ""
    public var customizations: RowndCustomizations = RowndCustomizations()

    // These will not be encoded
    public var appGroupPrefix: String?
    public var enableSmartLinkPasteBehavior: Bool = true
    public var signInLinkPattern: String = ".*\\.rownd\\.link$"
    public var deepLinkHandler: RowndDeepLinkHandlerDelegate?
    public var forceInstantUserConversion: Bool = false
    public var supertokens: RowndSuperTokensConfig?

    private enum CodingKeys: String, CodingKey {
        case apiUrl,
             baseUrl,
             subdomainExtension,
             appKey,
             forceDarkMode,
             postSignInRedirect,
             googleClientId,
             customizations
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
}
