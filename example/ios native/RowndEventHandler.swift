//
//  RowndEventHandler.swift
//  rownd_ios_example
//
//  Created by Matt Hamann on 5/15/24.
//

import Foundation
import Rownd

struct EventError: Error, CustomStringConvertible {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    public var description: String {
        return message
    }
}

class RowndEventHandler: RowndEventHandlerDelegate {
    func handleRowndEvent(_ event: RowndEvent) {
        switch event.event {
        case .signInCompleted:
            let userType = event.data?["user_type"]
            let appVariantUserType = event.data?["app_variant_user_type"]
            Task {
                let token = try await Rownd.getAccessToken()

                if token == nil {
                    throw EventError("Token unexpectedly nil")
                }
            }
            break

        default:
            break
        }
    }
}
