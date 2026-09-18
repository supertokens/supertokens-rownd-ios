import Foundation
import JWTDecode

internal enum AccessTokenDecoder {
    static func decode(_ accessToken: String) -> JWT? {
        let parts = accessToken.components(separatedBy: ".")
        guard parts.count == 3,
              isJSONObject(parts[0]),
              isJSONObject(parts[1]) else {
            return nil
        }
        return try? JWTDecode.decode(jwt: accessToken)
    }

    private static func isJSONObject(_ part: String) -> Bool {
        var base64 = part.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        // Avoid the Swift dictionary bridge during prevalidation. JWTDecode still
        // performs that bridge, so this guard cannot protect against runtime traps.
        return json is NSDictionary
    }
}
