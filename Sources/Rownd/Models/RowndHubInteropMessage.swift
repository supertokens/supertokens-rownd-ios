//
//  RowndHubInteropMessage.swift
//  ios native
//
//  Created by Matt Hamann on 6/14/22.
//

/*
 This structure relies on userData within the decodable in order to reference a parent value.
 Here's an example of how to use it:
 let jsonData = """
 {
     "type": "authentication",
     "payload": {
         "access_token": "foo",
         "refresh_token": "bar"
     }
 }
 """.data(using: .utf8)

 let decoder = JSONDecoder()
 decoder.userInfo[.messageType] = MessageTypeHolder()
 let result = try decoder.decode(RowndHubInteropMessage.self, from: jsonData!)
 print(result)

 */

import Foundation
import AnyCodable
import UIKit

struct RowndHubInteropMessage: Decodable {
    var type: MessageType
    var payload: MessagePayload?

    static func fromJson(message: String) throws -> RowndHubInteropMessage {
        let decoder = JSONDecoder()
        decoder.userInfo[.messageType] = MessageTypeHolder()
        let result = try decoder.decode(RowndHubInteropMessage.self, from: message.data(using: .utf8)!)
        return result
    }
}

enum MessageType: String, Codable {
    case authentication
    case signOut = "sign_out"
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

    public struct AuthenticationMessage: Codable {
        var accessToken: String
        var refreshToken: String
        var frontToken: String
        var antiCSRF: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case frontToken = "front_token"
            case antiCSRF = "anti_csrf"
        }
    }

    public struct SignOutMessage: Codable {
        var wasUserInitiated: Bool?

        enum CodingKeys: String, CodingKey {
            case wasUserInitiated = "was_user_initiated"
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
