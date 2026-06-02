//
//  RphInit.swift
//  Rownd
//
//  Created by Bobby on 4/10/25.
//

import Foundation
import Gzip

struct RphInit: Encodable {
    let accessToken: String?
    let refreshToken: String?
    let frontToken: String?
    let antiCSRF: String?
    let appId: String?
    let appUserId: String?
    
    init(
        accessToken: String?,
        refreshToken: String?,
        frontToken: String? = nil,
        antiCSRF: String? = nil,
        appId: String?,
        appUserId: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.frontToken = frontToken
        self.antiCSRF = antiCSRF
        self.appId = appId
        self.appUserId = appUserId
    }
    
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case frontToken = "front_token"
        case antiCSRF = "anti_csrf"
        case appId = "app_id"
        case appUserId = "app_user_id"
    }
    
    /// Computes a value suitable for appending to a URL fragment. The returned value is JSON-encoded, Gzipped, and base64 encoded with a "gz." prefix
    func valueForURLFragment() throws -> String {
        let encoder = JSONEncoder()
        let json = try encoder.encode(self)
        let compressed = try Data(json).gzipped(level: .bestCompression)
        let base64 = compressed.base64EncodedString()

        return "gz.\(base64)"
    }
}
