import Foundation

struct SuperTokensSessionTokens: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let frontToken: String
    let antiCSRF: String?
}

extension HTTPURLResponse {
    func headerValue(named name: String) -> String? {
        for (key, value) in allHeaderFields {
            guard let key = key as? String,
                  key.caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            return value as? String
        }

        return nil
    }
}
