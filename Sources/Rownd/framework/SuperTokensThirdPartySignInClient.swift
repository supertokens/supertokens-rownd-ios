import Foundation

struct SuperTokensThirdPartySignInRequest: Encodable {
    let thirdPartyId: String
    let clientType: String?
    let oAuthTokens: OAuthTokens?
    let redirectURIInfo: RedirectURIInfo?

    struct OAuthTokens: Encodable {
        let idToken: String

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
        }
    }

    struct RedirectURIInfo: Encodable {
        let redirectURIOnProviderDashboard: String
        let redirectURIQueryParams: [String: String]
    }
}

struct SuperTokensThirdPartySignInResponse: Decodable {
    let status: String?
    let createdNewRecipeUser: Bool?

    var userType: UserType {
        createdNewRecipeUser == true ? .NewUser : .ExistingUser
    }
}

struct SuperTokensThirdPartySignInClient {
    private let apiDomainOverride: String?
    private let apiBasePathOverride: String?
    private let session: URLSession

    init(
        apiDomain: String? = nil,
        apiBasePath: String? = nil,
        session: URLSession = .shared
    ) {
        self.apiDomainOverride = apiDomain
        self.apiBasePathOverride = apiBasePath
        self.session = session
    }

    func signInWithGoogle(idToken: String) async throws -> SuperTokensThirdPartySignInResponse {
        try await signIn(
            SuperTokensThirdPartySignInRequest(
                thirdPartyId: "google",
                clientType: nil,
                oAuthTokens: .init(idToken: idToken),
                redirectURIInfo: nil
            )
        )
    }

    func signInWithApple(authorizationCode: String, clientType: String? = nil) async throws -> SuperTokensThirdPartySignInResponse {
        try await signIn(
            SuperTokensThirdPartySignInRequest(
                thirdPartyId: "apple",
                clientType: clientType,
                oAuthTokens: nil,
                redirectURIInfo: .init(
                    redirectURIOnProviderDashboard: "",
                    redirectURIQueryParams: ["code": authorizationCode]
                )
            )
        )
    }

    private func signIn(_ body: SuperTokensThirdPartySignInRequest) async throws -> SuperTokensThirdPartySignInResponse {
        let supertokens = apiDomainOverride == nil || apiBasePathOverride == nil ? try Rownd.requireSuperTokensConfig() : nil
        let apiDomain = apiDomainOverride ?? supertokens!.apiDomain
        let apiBasePath = apiBasePathOverride ?? supertokens!.apiBasePath

        guard var components = URLComponents(string: apiDomain) else {
            throw RowndError("Invalid SuperTokens apiDomain")
        }

        let normalizedBasePath = apiBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = normalizedBasePath.isEmpty ? "/signinup" : "/\(normalizedBasePath)/signinup"
        guard let url = components.url else {
            throw RowndError("Invalid SuperTokens signinup URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("thirdparty", forHTTPHeaderField: "rid")
        request.setValue("4.1", forHTTPHeaderField: "fdi-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RowndError("SuperTokens signinup returned a non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RowndError("SuperTokens signinup failed with status code \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(SuperTokensThirdPartySignInResponse.self, from: data)
    }
}
