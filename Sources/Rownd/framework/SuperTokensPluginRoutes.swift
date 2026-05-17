import Foundation

enum SuperTokensPluginRoutes {
    static func url(_ path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let supertokens = try Rownd.requireSuperTokensConfig()

        guard var components = URLComponents(string: supertokens.apiDomain) else {
            throw RowndError("Invalid SuperTokens apiDomain")
        }

        let basePath = supertokens.apiBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pluginPath = path.hasPrefix("/") ? path : "/\(path)"
        components.path = "/\(basePath)/plugin/rownd\(pluginPath)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw RowndError("Invalid SuperTokens plugin URL")
        }

        return url
    }
}
