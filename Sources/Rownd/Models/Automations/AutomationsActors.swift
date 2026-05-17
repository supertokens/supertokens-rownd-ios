//
//  AutomationsActors.swift
//  Rownd
//
//  Created by Michael Murray on 5/24/23.
//

import Foundation
import AnyCodable

func AutomationActorRequireAuthentication(_ args: [String: AnyCodable]?) {
    logger.log("Trigger Automation: rownd.requestSignIn()")
    guard let method = args?["method"] else {
        Rownd.requestSignIn(jsFnOptions: args)
        return
    }
    let signInMethod = "\(method)"
    switch signInMethod {
    case "google":
        Rownd.requestSignIn(with: .googleId)
    case "apple":
        Rownd.requestSignIn(with: .appleId)
    default:
        Rownd.requestSignIn(jsFnOptions: args)
    }
}

public let AutomationActors: [RowndAutomationActionType: ( Dictionary<String, AnyCodable>? ) -> Void] = [
    RowndAutomationActionType.requireAuthentication: AutomationActorRequireAuthentication
]
