//
//  File.swift
//  
//
//  Created by Matt Hamann on 10/4/24.
//

import Foundation

struct Redact {
    static func urlForLogging(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "[invalid URL]"
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "[invalid URL]"
    }

    static func redactSensitiveKeys(in jsonString: String?) -> String {

        guard let jsonString = jsonString else {
            return ""
        }

        let pattern = #"\\?"(accessToken|refreshToken|refresh_token|access_token|frontToken|front_token|antiCSRF|antiCsrf|anti_csrf)\\?"\s*:\s*\\?"[^"\\]*\\?""#

        // Use regular expression to search for the pattern
        let regex = try! NSRegularExpression(pattern: pattern, options: [])

        // Perform the replacement: redact the value
        let redactedString = regex.stringByReplacingMatches(
            in: jsonString,
            options: [],
            range: NSRange(location: 0, length: jsonString.utf16.count),
            withTemplate: #""$1": "[REDACTED]""#
        )

        return redactedString
    }
}
