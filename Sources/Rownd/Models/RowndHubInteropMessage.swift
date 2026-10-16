//
//  RowndHubInteropMessage.swift
//  ios native
//
//  Created by Matt Hamann on 6/14/22.
//

import Foundation
import AnyCodable
import UIKit

struct RowndHubInteropMessage: Decodable {
    var type: MessageType
    var payload: MessagePayload?

    static func fromJson(message: String) throws -> RowndHubInteropMessage {
        let data = Data(message.utf8)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String,
            type == "sign_in",
           let payload = object["payload"] as? [String: Any] {
            let allowed: Set<String> = ["was_user_initiated", "email_change"]
            guard Set(payload.keys).isSubset(of: allowed) else { throw RowndError("Unexpected continuation field") }
            if let descriptor = payload["email_change"] as? [String: Any] {
                guard Set(descriptor.keys) == ["version", "request_id", "local_draft", "expires_at"],
                      let draft = descriptor["local_draft"] as? [String: Any],
                      Set(draft.keys) == ["owner_id", "tenant_id", "configuration", "changes"],
                      let changes = draft["changes"] as? [String: Any], Set(changes.keys) == ["email"],
                      try JSONSerialization.data(withJSONObject: descriptor).count <= 32 * 1024 else {
                    throw RowndError("Invalid continuation descriptor")
                }
            }
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.messageType] = MessageTypeHolder()
        let result = try decoder.decode(RowndHubInteropMessage.self, from: data)
        return result
    }
}

enum MessageType: String, Codable {
    case authentication
    case signOut = "sign_out"
    case signIn = "sign_in"
    case closeHubViewController = "close_hub_view_controller"
    case triggerSignInWithApple = "trigger_sign_in_with_apple"
    case triggerSignInWithGoogle = "trigger_sign_in_with_google"
    case userDataUpdate = "user_data_update"
    case tryAgain = "try_again"
    case hubLoaded = "hub_loaded"
    case hubResize = "hub_resize"
    case canTouchBackgroundToDismiss = "can_touch_background_to_dismiss"
    case event = "event"
    case authChallengeInitiated = "auth_challenge_initiated"
    case authChallengeCleared = "auth_challenge_cleared"
    case verifyEmail = "verify_email"
    case unknown

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let type = try container.decode(String.self)
        self = MessageType(rawValue: type) ?? .unknown

        if let messageType = decoder.userInfo[.messageType] as? MessageTypeHolder {
            messageType.type = self
        }
    }
}

enum MessagePayload: Decodable {
    case authentication(AuthenticationMessage)
    case userDataUpdate(UserDataUpdateMessage)
    case signOut(SignOutMessage)
    case signIn(SignInMessage)
    case closeHubViewController
    case unknown
    case triggerSignInWithApple(TriggerSignInWithAppleMessage)
    case triggerSignInWithGoogle(TriggerSignInWithGoogleMessage)
    case hubLoaded
    case tryAgain
    case hubResize(TriggerHubResize)
    case canTouchBackgroundToDismiss(CanTouchBackgroundToDismiss)
    case event(RowndEvent)
    case authChallengeInitiated(PayloadAuthChallengeInitiated)
    case authChallengeCleared
    case verifyEmail(VerifyEmailMessage)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        // We're accessing a value from the parent that must exist, else we can't continue
        guard let messageType = decoder.userInfo[.messageType] as? MessageTypeHolder, let messageTypeStr = messageType.type else {
            self = .unknown
            return
        }
        let type = messageTypeStr

        let objectContainer = try decoder.singleValueContainer()

        switch type {
        case .signIn:
            self = .signIn(try objectContainer.decode(SignInMessage.self))
        case .triggerSignInWithApple:
            let payload = try objectContainer.decode(TriggerSignInWithAppleMessage.self)
            self = .triggerSignInWithApple(payload)

        case .triggerSignInWithGoogle:
            let payload = try objectContainer.decode(TriggerSignInWithGoogleMessage.self)
            self = .triggerSignInWithGoogle(payload)

        case .authentication:
            let payload = try objectContainer.decode(AuthenticationMessage.self)
            self = .authentication(payload)

        case .closeHubViewController:
            self = .closeHubViewController

        case .userDataUpdate:
            let payload = try objectContainer.decode(UserDataUpdateMessage.self)
            self = .userDataUpdate(payload)

        case .hubResize:
            let payload = try objectContainer.decode(TriggerHubResize.self)
            self = .hubResize(payload)

        case .canTouchBackgroundToDismiss:
            let payload = try objectContainer.decode(CanTouchBackgroundToDismiss.self)
            self = .canTouchBackgroundToDismiss(payload)

        case .signOut:
            let payload = try objectContainer.decode(SignOutMessage.self)
            self = .signOut(payload)

        case .tryAgain:
            self = .tryAgain

        case .hubLoaded:
            self = .hubLoaded

        case .event:
            let payload = try objectContainer.decode(RowndEvent.self)
            self = .event(payload)

        case .unknown:
            self = .unknown
            
        case .authChallengeInitiated:
            let payload = try objectContainer.decode(PayloadAuthChallengeInitiated.self)
            self = .authChallengeInitiated(payload)
            
        case .authChallengeCleared:
            self = .authChallengeCleared

        case .verifyEmail:
            let payload = try objectContainer.decode(VerifyEmailMessage.self)
            self = .verifyEmail(payload)
        }
    }
    
    public struct PayloadAuthChallengeInitiated: Codable {
        var challengeId: String
        var userIdentifier: String

        enum CodingKeys: String, CodingKey {
            case challengeId = "challenge_id"
            case userIdentifier = "user_identifier"
        }
    }

    public struct VerifyEmailMessage: Codable {
        var requestId: String

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }

    public struct AuthenticationMessage: Codable {
        var accessToken: String
        var refreshToken: String
        var frontToken: String
        var antiCSRF: String?
        var userType: String?
        var appVariantUserType: String?
        var method: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case frontToken = "front_token"
            case antiCSRF = "anti_csrf"
            case userType = "user_type"
            case appVariantUserType = "app_variant_user_type"
            case method
        }

        var signInCompletedEventData: [String: String] {
            var data: [String: String] = [:]

            if let userType {
                data["user_type"] = userType
            }

            if let appVariantUserType {
                data["app_variant_user_type"] = appVariantUserType
            }

            if let method {
                data["method"] = method
            }

            return data
        }
    }

    public struct SignOutMessage: Codable {
        var wasUserInitiated: Bool?

        enum CodingKeys: String, CodingKey {
            case wasUserInitiated = "was_user_initiated"
        }
    }

    struct SignInMessage: Decodable {
        let wasUserInitiated: Bool?
        let emailChange: EmailChangeDescriptor?
        enum CodingKeys: String, CodingKey {
            case wasUserInitiated = "was_user_initiated"
            case emailChange = "email_change"
        }
    }

    public struct TriggerSignInWithGoogleMessage: Codable {
        var intent: RowndSignInIntent?
        var hint: String?

        enum CodingKeys: String, CodingKey {
            case intent, hint
        }
    }

    public struct TriggerSignInWithAppleMessage: Codable {
        var intent: RowndSignInIntent?

        enum CodingKeys: String, CodingKey {
            case intent
        }
    }

    public struct UserDataUpdateMessage: Codable {
        var data: [String: AnyCodable]
        var meta: [String: AnyCodable]?
        var state: UserStateVal?
        var authLevel: UserAuthLevel?

        enum CodingKeys: String, CodingKey {
            case data = "data"
            case meta = "meta"
            case state = "state"
            case authLevel = "auth_level"
        }

        func toUserState() -> UserState {
            return UserState(
                data: data,
                meta: meta,
                state: state ?? .enabled,
                authLevel: authLevel ?? .unknown
            )
        }
    }

    public struct TriggerHubResize: Codable {
        var height: String?

        enum CodingKeys: String, CodingKey {
            case height
        }
    }

    public struct CanTouchBackgroundToDismiss: Codable {
        var enable: String?

        enum CodingKeys: String, CodingKey {
            case enable
        }
    }
    
    
}

class MessageTypeHolder {
    var type: MessageType?
}

extension CodingUserInfoKey {
    static let messageType = CodingUserInfoKey(rawValue: "ThisMessageType")!
}
