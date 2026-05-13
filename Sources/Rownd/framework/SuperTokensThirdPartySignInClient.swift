import Foundation

struct SuperTokensThirdPartySignInRequest: Encodable {
    let thirdPartyId: String
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
    private let apiDomain: String
    private let apiBasePath: String
    private let session: URLSession

    init(
        apiDomain: String? = Rownd.config.supertokens?.apiDomain,
        apiBasePath: String? = Rownd.config.supertokens?.apiBasePath,
        session: URLSession = .shared
    ) {
        self.apiDomain = apiDomain ?? ""
        self.apiBasePath = apiBasePath ?? ""
        self.session = session
    }

    func signInWithGoogle(idToken: String) async throws -> SuperTokensThirdPartySignInResponse {
        try await signIn(
            SuperTokensThirdPartySignInRequest(
                thirdPartyId: "google",
                oAuthTokens: .init(idToken: idToken),
                redirectURIInfo: nil
            )
        )
    }

    func signInWithApple(authorizationCode: String) async throws -> SuperTokensThirdPartySignInResponse {
        try await signIn(
            SuperTokensThirdPartySignInRequest(
                thirdPartyId: "apple",
                oAuthTokens: nil,
                redirectURIInfo: .init(
                    redirectURIOnProviderDashboard: "",
                    redirectURIQueryParams: ["code": authorizationCode]
                )
            )
        )
    }

    private func signIn(_ body: SuperTokensThirdPartySignInRequest) async throws -> SuperTokensThirdPartySignInResponse {
        guard var components = URLComponents(string: apiDomain) else {
            throw RowndError("Invalid SuperTokens apiDomain")
        }

        components.path = apiBasePath + "/signinup"
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
