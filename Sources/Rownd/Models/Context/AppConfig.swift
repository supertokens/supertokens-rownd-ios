//
//  AppConfig.swift
//  framework
//
//  Created by Matt Hamann on 6/23/22.
//

import Foundation
import UIKit
import ReSwift
import ReSwiftThunk
import Get
import AnyCodable

public struct AppConfigState: Hashable {
    public var isLoading: Bool = false
    public var id: String?
    public var icon: String?
    public var name: String?
    public var userVerificationFields: [String]?
    public var schema: [String: AppSchemaField]?
    public var config: AppConfigConfig?
}

extension AppConfigState: Codable {
    enum CodingKeys: String, CodingKey {
        case id, icon, schema, config, name
        case userVerificationFields = "user_verification_fields"
    }
}

public struct AppConfigConfig: Hashable {
    public var automations: [RowndAutomation]?
    public var hub: AppHubConfigState?
    public var customizations: AppCustomizationsConfigState?
    public var subdomain: String?
    var supertokens: SuperTokensConfig?
}

struct SuperTokensConfig: Hashable, Codable {
    var appInfo: SuperTokensAppInfo
}

struct SuperTokensAppInfo: Hashable, Codable {
    var apiDomain: String
    var apiBasePath: String?
}

extension AppConfigConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case hub, customizations, subdomain, automations, supertokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Attempt to decode the automations array, handling each RowndAutomation individually
        if var nestedContainer = try? container.nestedUnkeyedContainer(forKey: .automations) {
            var tempAutomations = [RowndAutomation]()

            while !nestedContainer.isAtEnd {
                if let automation = try? nestedContainer.decode(RowndAutomation.self) {
                    tempAutomations.append(automation)
                } else {
                    _ = try? nestedContainer.decode(AnyCodable.self) // This line skips over the bad entry
                }
            }

            self.automations = tempAutomations.isEmpty ? nil : tempAutomations
        } else {
            self.automations = nil
        }

        self.hub = try? container.decode(AppHubConfigState.self, forKey: .hub)
        self.customizations = try? container.decode(AppCustomizationsConfigState.self, forKey: .customizations)
        self.subdomain = try? container.decode(String.self, forKey: .subdomain)
        self.supertokens = try? container.decode(SuperTokensConfig.self, forKey: .supertokens)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // Encode automations, skipping any that fail to encode
        if let automations = automations {
            var nestedContainer = container.nestedUnkeyedContainer(forKey: .automations)
            for automation in automations {
                do {
                    try nestedContainer.encode(automation)
                } catch {
                    continue // Skip the automation if encoding fails
                }
            }
        }

        try container.encodeIfPresent(hub, forKey: .hub)
        try container.encodeIfPresent(customizations, forKey: .customizations)
        try container.encodeIfPresent(subdomain, forKey: .subdomain)
        try container.encodeIfPresent(supertokens, forKey: .supertokens)
    }

    public func toDictionary() throws -> [String: Any?] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
    }
}

public struct AppSchemaField: Hashable {
    public var displayName: String?
    public var type: String?
    public var required: Bool?
    public var ownedBy: String?
    public var encryption: AppSchemaFieldEncryption?
}

extension AppSchemaField: Codable {
    enum CodingKeys: String, CodingKey {
        case type, required, encryption
        case displayName = "display_name"
        case ownedBy = "owned_by"
    }
}

public struct AppSchemaFieldEncryption: Hashable, Codable {
    public var state: AppSchemaEncryptionState?
}

public enum AppSchemaEncryptionState: String, Codable {
    case enabled, disabled
}

public struct AppHubConfigState: Hashable {
    public var auth: AppHubAuthConfigState?
    public var customizations: AppHubCustomizationsConfigState?
    public var customStyles: [AppHubCustomStylesConfigState]?
}

extension AppHubConfigState: Codable {
    enum CodingKeys: String, CodingKey {
        case auth, customizations
        case customStyles = "custom_styles"
    }
}

public struct AppHubAuthConfigState: Hashable {
    public var signInMethods: SignInMethods?
    public var useExplicitSignUpFlow: Bool?
}

extension AppHubAuthConfigState: Codable {
    enum CodingKeys: String, CodingKey {
        case signInMethods = "sign_in_methods"
        case useExplicitSignUpFlow = "use_explicit_sign_up_flow"
    }
}

public struct AppCustomizationsConfigState: Hashable {
    public var primaryColor: String?
}

extension AppCustomizationsConfigState: Codable {
    enum CodingKeys: String, CodingKey {
        case primaryColor = "primary_color"
    }
}

public struct AppHubCustomizationsConfigState: Hashable {
    public var fontFamily: String?
    public var darkMode: String?
    public var primaryColor: String?
    public var primaryColorDarkMode: String?
}

extension AppHubCustomizationsConfigState: Codable {
    enum CodingKeys: String, CodingKey {
        case fontFamily = "font_family"
        case darkMode = "dark_mode"
        case primaryColor = "primary_color"
        case primaryColorDarkMode = "primary_color_dark_mode"
    }
}

public struct AppHubCustomStylesConfigState: Hashable {
    public var content: String
}

extension AppHubCustomStylesConfigState: Codable {
    enum CodingKeys: String, CodingKey {
        case content
    }
}

public struct SignInMethods: Hashable {
    public var google: GoogleSignInMethodConfig?
    public var passkeys: PasskeysSignInMethodConfig?
}

extension SignInMethods: Codable {
    enum CodingKeys: String, CodingKey {
        case google, passkeys
    }
}

public struct GoogleSignInMethodConfig: Hashable {
    public var enabled: Bool?
    public var serverClientId: String?
    public var iosClientId: String?
}

extension GoogleSignInMethodConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case enabled
        case serverClientId = "client_id"
        case iosClientId = "ios_client_id"
    }
}

public struct PasskeysSignInMethodConfig: Hashable {
    public var enabled: Bool?
    public var domains: [String]?
}

extension PasskeysSignInMethodConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case enabled, domains
    }
}

struct SetAppConfig: Action {
    var payload: AppConfigState
}

struct SetAppLoading: Action {
    var isLoading: Bool
}

func appConfigReducer(action: Action, state: AppConfigState?) -> AppConfigState {
    var state = state ?? AppConfigState()

    switch action {
    case let action as SetAppConfig:
        state = action.payload
        state.isLoading = false
    case let action as SetAppLoading:
        state.isLoading = action.isLoading
    default:
        break
    }

    return state
}

// MARK: API / side-effecty things

// Easily unwrap the main payload from the `app` key
struct AppConfigResponse: Decodable {
    var app: AppConfigState
}

class AppConfig {
    static func validateSuperTokensConfig(_ appConfig: AppConfigResponse) throws {
        guard let configured = Rownd.config.supertokens,
            let serverConfig = appConfig.app.config?.supertokens?.appInfo
        else {
            return
        }

        if serverConfig.apiDomain != configured.apiDomain {
            throw RowndError(
                "App config SuperTokens apiDomain \(serverConfig.apiDomain) does not match configured value \(configured.apiDomain)"
            )
        }

        if let serverBasePath = serverConfig.apiBasePath,
            serverBasePath != configured.apiBasePath
        {
            throw RowndError(
                "App config SuperTokens apiBasePath \(serverBasePath) does not match configured value \(configured.apiBasePath)"
            )
        }
    }

    static func requestAppState() -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            guard let state = getState() else { return }
            guard !state.appConfig.isLoading else { return }
            dispatch(SetAppLoading(isLoading: true))

            Task {
                let appConfig = await AppConfig.fetch()

                DispatchQueue.main.async {
                    if let appConfig = appConfig {
                        dispatch(SetAppConfig(payload: appConfig.app))
                    }
                    dispatch(SetAppLoading(isLoading: false))
                }
            }
        }
    }

    static func fetch() async -> AppConfigResponse? {
        do {
            let appConfig: AppConfigResponse = try await Rownd.apiClient.send(Get.Request(url: URL(string: "/hub/app-config")!, method: "get")).value
            try validateSuperTokensConfig(appConfig)

            return appConfig
        } catch {
            logger.error("Failed to fetch app config: \(String(describing: error), privacy: .auto)")
            return nil
        }
    }
}
