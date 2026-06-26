//
//  AutomationTests.swift
//  
//
//  Created by Michael Murray on 8/19/24.
//

import XCTest

@testable import SuperTokensRownd

final class AutomationTests: XCTestCase {
    
    let appConfigStringWithAutomationOrRules = """
    { "hub": { "customizations": { "rounded_corners": true, "visual_swoops": true, "blur_background": true, "dark_mode": "auto" }, "auth": { "sign_in_methods": { "email": { "enabled": true }, "phone": { "enabled": false }, "apple": { "enabled": false, "client_id": "" }, "google": { "enabled": false, "client_id": "", "ios_client_id": "", "scopes": [] }, "crypto_wallet": { "enabled": false }, "anonymous": { "enabled": true } }, "show_app_icon": false } }, "automations": [ { "rules": [ { "$or": [ { "entity_type": "metadata", "attribute": "is_authenticated", "condition": "EQUALS", "value": false }, { "entity_type": "metadata", "attribute": "auth_level", "condition": "EQUALS", "value": "instant" } ] }, { "entity_type": "scope", "attribute": "url", "condition": "EQUALS", "value": "https://app.rownd.io" } ], "triggers": [ { "type": "HTML_SELECTOR", "value": ".random" } ], "actions": [ { "type": "EDIT_ELEMENTS", "args": { "style": { "display": "none !important" }, "selector": ".random" } } ], "id": "cm01g3wji009e7fdjp6767sa8", "app_id": "406650865825350227", "platform": "web", "template": "hide_content", "name": "Untitled automation", "created_at": "2024-08-19T20:25:32.286Z", "updated_at": "2024-08-19T20:25:32.286Z", "state": "enabled", "order": 10 } ], "profile_storage_version": "v1" }
    """

    func testDecodingAppConfigAutomation() {
        do {
            let decoder = JSONDecoder()
            let appConfig = try decoder.decode(
                AppConfigConfig.self,
                from: (appConfigStringWithAutomationOrRules.data(using: .utf8) ?? Data())
            )
            
            guard let automations = appConfig.automations else {
                return XCTFail("Automations are nil")
            }
            
            let automation = automations[0]
            
            let hasOrRule = automation.rules.contains { rule in
                if case .or(_) = rule {
                    return true
                } else {
                    return false
                }
            }
            
            XCTAssertTrue(hasOrRule, "Rule contains a valid Automation OR rule")
            XCTAssertTrue(automation.triggers.first?.type == RowndAutomationTriggerType.htmlSelector, "HTML_SELECTOR is the expected trigger type")
            
            do {
                _ = try appConfig.toDictionary()
            } catch {
                XCTFail("Failed to encode app config string \(error)")
            }
            
        } catch {
            XCTFail("Failed to decode app config string \(error)")
        }
        
    }
    
    
    func testDecodingAppConfigAutomation2() {
        do {
            let appConfigString = """
            { "hub": { "customizations": { "rounded_corners": true, "visual_swoops": true, "blur_background": true, "dark_mode": "auto" }, "auth": { "sign_in_methods": { "email": { "enabled": true }, "phone": { "enabled": false }, "apple": { "enabled": false, "client_id": "" }, "google": { "enabled": false, "client_id": "", "ios_client_id": "", "scopes": [] }, "crypto_wallet": { "enabled": false }, "anonymous": { "enabled": true } }, "show_app_icon": false } }, "automations": [ { "rules": [ { "entity_type": "metadata", "attribute": "auth_level", "condition": "EQUALS", "value": "instant" } ], "triggers": [ { "type": "TIME", "value": "3h" } ], "actions": [ { "type": "EDIT_ELEMENTS", "args": { "style": { "display": "none !important" }, "selector": ".random" } } ], "id": "cm01g3wji009e7fdjp6767sa8", "app_id": "406650865825350227", "platform": "web", "template": "hide_content", "name": "Untitled automation", "created_at": "2024-08-19T20:25:32.286Z", "updated_at": "2024-08-19T20:25:32.286Z", "state": "enabled", "order": 10 } ], "profile_storage_version": "v1" }
            """
            let decoder = JSONDecoder()
            let appConfig = try decoder.decode(
                AppConfigConfig.self,
                from: (appConfigString.data(using: .utf8) ?? Data())
            )
            
            guard let automations = appConfig.automations else {
                return XCTFail("Automations are nil")
            }
            
            let automation = automations[0]
            
            var automationRule: RowndAutomationRule? = nil
            automation.rules.forEach { rule in
                if case let .rule(Rule) = rule {
                    automationRule = Rule
                }
            }
            
            XCTAssertTrue(automationRule?.condition == RowndAutomationRuleCondition.equals)
            XCTAssertTrue(automation.triggers.first?.value == "3h")
            
            do {
                _ = try appConfig.toDictionary()
            } catch {
                XCTFail("Failed to encode app config string \(error)")
            }
            
        } catch {
            XCTFail("Failed to decode app config string \(error)")
        }
        
    }
    
    func testFailedDecodingAppConfigAutomationFallback() {
        do {
            let invalidAppConfigString = """
            { "hub": { "customizations": { "rounded_corners": true, "visual_swoops": true, "blur_background": true, "dark_mode": "auto" }, "auth": { "sign_in_methods": { "email": { "enabled": true }, "phone": { "enabled": false }, "apple": { "enabled": false, "client_id": "" }, "google": { "enabled": false, "client_id": "", "ios_client_id": "", "scopes": [] }, "crypto_wallet": { "enabled": false }, "anonymous": { "enabled": true } }, "show_app_icon": false } }, "automations": [ { "rules": [ { "random": "randy" } ], "id": "cm01g3wji009e7fdjp6767sa8", "app_id": "406650865825350227", "platform": "web", "template": "hide_content", "name": "Untitled automation", "state": "enabled" } ] }
            """
            let decoder = JSONDecoder()
            let appConfig = try decoder.decode(
                AppConfigConfig.self,
                from: (invalidAppConfigString.data(using: .utf8) ?? Data())
            )
            
            XCTAssertNil(appConfig.automations)
            
            do {
                _ = try appConfig.toDictionary()
            } catch {
                XCTFail("Failed to encode app config string \(error)")
            }
        } catch {
            XCTFail("Failed to decode app config string \(error)")
        }
        
    }
}
