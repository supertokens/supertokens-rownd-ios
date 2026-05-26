//
//  ContentView.swift
//  ios native
//
//  Created by Matt Hamann on 6/10/22.
//

import SwiftUI
import Rownd
import AnyCodable
import WidgetKit

struct ContentView: View {
    @StateObject private var authState = Rownd.getInstance().state().subscribe { $0.auth }
    @StateObject private var user = Rownd.getInstance().state().subscribe { $0.user }
    @StateObject private var state = Rownd.getInstance().state().subscribe { $0 }

    @State private var scenarioStatus = "idle"
    @State private var protectedResult = ""
    @State private var isFetchingProtected = false
    @State private var isTestingRefresh = false
    @State private var refreshSimulationCompleted = false
    @State private var presentEditName = false
    @State private var firstName = ""

    private let superTokensRefreshTokenStorageKey = "st-storage-item-st-refresh-token"

    private var isAuthenticated: Bool {
        authState.current.isAuthenticated
    }

    private var userId: String {
        user.current.data["user_id"]?.value as? String ?? "not loaded"
    }

    private var displayName: String {
        let firstName = user.current.data["first_name"]?.value as? String
        let email = user.current.data["email"]?.value as? String
        return firstName?.isEmpty == false ? firstName! : email ?? "My account"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                statusCard

                if isAuthenticated {
                    postLoginCard
                        .accessibilityIdentifier("e2e-home-screen")
                } else {
                    loginCard
                }

                if E2ESupport.isEnabled {
                    e2eCard
                }
            }
            .padding(16)
        }
        .background(Color(red: 0.965, green: 0.969, blue: 0.984))
        .onChange(of: state.current.lastUpdateTs) { _ in
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private var heroCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("All authentication methods example")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Try the Hub auth flows")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("This iOS example loads the local Hub and backend to test email magic links, Google login, guest login, protected requests, and sign out.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                StatusRow(label: "Host", value: state.current.isInitialized ? "ready" : "loading")
                StatusRow(label: "Auth", value: isAuthenticated ? "signed_in" : "signed_out")
                StatusRow(label: "Example", value: "all-authentication-methods-ios")
                StatusRow(label: "Scenario", value: scenarioStatus)
                StatusRow(label: "User", value: userId)
                E2EStatusView()
            }
        }
    }

    private var loginCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Flows")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Use these controls to launch each enabled Hub auth method.")
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    FlowButton("Open Rownd auth UI") {
                        scenarioStatus = "modal_open_requested"
                        Rownd.requestSignIn()
                    }
                    .accessibilityIdentifier("e2e-sign-in-account-button")

                    FlowButton("Sign in with email") {
                        scenarioStatus = "email_requested"
                        Rownd.requestSignIn(with: .email)
                    }

                    FlowButton("Direct Google login") {
                        scenarioStatus = "direct_google_requested"
                        Rownd.requestSignIn(with: .googleId)
                    }

                    FlowButton("Continue as guest", style: .secondary) {
                        scenarioStatus = "guest_requested"
                        Rownd.requestSignIn(with: .anonymous)
                    }
                    .accessibilityIdentifier("e2e-sign-in-guest-button")
                }
            }
        }
    }

    private var postLoginCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Post-login page")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Use the protected request to verify the SuperTokens session and claims.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    FlowButton("Profile", style: .compact) {
                        scenarioStatus = "manage_account_requested"
                        Rownd.manageAccount()
                    }
                    .accessibilityIdentifier("e2e-manage-account-button")

                    Menu {
                        Button(displayName) {
                            Rownd.manageAccount()
                        }

                        Button("Edit name") {
                            firstName = user.current.data["first_name"]?.value as? String ?? ""
                            presentEditName = true
                        }

                        Button("Refresh token") {
                            Rownd._refreshToken()
                        }
                        .accessibilityIdentifier("e2e-refresh-token-button")

                        Button("Sign out") {
                            Rownd.signOut()
                            scenarioStatus = "signed_out"
                        }
                        .accessibilityIdentifier("e2e-sign-out-button")
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.title2)
                    }
                }

                FlowButton(isFetchingProtected ? "Fetching..." : "Fetch protected resource") {
                    Task { await fetchProtectedResource() }
                }
                .disabled(isFetchingProtected)

                FlowButton(refreshSimulationCompleted ? "Reset refresh test" : refreshTestButtonTitle) {
                    Task {
                        if refreshSimulationCompleted {
                            await resetRefreshSimulation()
                        } else {
                            await testSessionRefresh()
                        }
                    }
                }
                .disabled(isTestingRefresh)

                FlowButton("Sign out", style: .secondary) {
                    Rownd.signOut()
                    scenarioStatus = "signed_out"
                }

                Text(protectedResult.isEmpty ? "Protected response will appear here." : protectedResult)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .padding(12)
                    .background(Color(red: 0.059, green: 0.09, blue: 0.165))
                    .foregroundStyle(Color(red: 0.886, green: 0.91, blue: 0.941))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .sheet(isPresented: $presentEditName) {
                VStack(spacing: 16) {
                    Text("Update your name below.")
                        .font(.headline)
                    TextField("First name", text: $firstName)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Cancel") {
                            presentEditName = false
                        }
                        Button("Save") {
                            Rownd.user.set(field: "first_name", value: AnyCodable(firstName))
                            presentEditName = false
                        }
                    }
                }
                .padding()
            }
        }
    }

    private var e2eCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("E2E controls")
                    .font(.headline)

                FlowButton("E2E sign in") {
                    Task {
                        try? await E2ESupport.resetHarness()
                        try? await E2ESupport.createSession()
                        scenarioStatus = "e2e_session_created"
                    }
                }
                .accessibilityIdentifier("e2e-create-session-button")

                FlowButton("E2E update profile") {
                    Task {
                        try? await E2ESupport.updateProfile()
                        scenarioStatus = "e2e_profile_updated"
                    }
                }
                .accessibilityIdentifier("e2e-update-profile-button")

                FlowButton("E2E sign out all", style: .secondary) {
                    try? Rownd.signOut(scope: .all)
                    scenarioStatus = "e2e_sign_out_all_requested"
                }
                .accessibilityIdentifier("e2e-sign-out-all-button")
            }
        }
    }

    private func fetchProtectedResource() async {
        isFetchingProtected = true
        scenarioStatus = "protected_requested"
        defer { isFetchingProtected = false }

        let apiURL = E2ESupport.apiURL ?? ExampleAppConfig.apiURL
        let request = URLRequest(url: apiURL.appendingPathComponent("test/protected"))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            protectedResult = "HTTP \(statusCode)\n\(body)"
            scenarioStatus = (200..<300).contains(statusCode) ? "protected_loaded" : "protected_failed"
        } catch {
            protectedResult = String(describing: error)
            scenarioStatus = "protected_failed"
        }
    }

    private var refreshTestButtonTitle: String {
        isTestingRefresh ? "Testing refresh..." : "Test session refresh"
    }

    private func testSessionRefresh() async {
        isTestingRefresh = true
        scenarioStatus = "refresh_test_requested"
        defer { isTestingRefresh = false }

        let refreshTokenBefore = UserDefaults.standard.string(forKey: superTokensRefreshTokenStorageKey)
        let apiURL = E2ESupport.apiURL ?? ExampleAppConfig.apiURL
        let request = URLRequest(url: apiURL.appendingPathComponent("test/refresh"))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            let refreshTokenAfter = UserDefaults.standard.string(forKey: superTokensRefreshTokenStorageKey)
            let refreshTokenChanged = refreshTokenBefore != nil
                && refreshTokenAfter != nil
                && refreshTokenBefore != refreshTokenAfter

            refreshSimulationCompleted = true
            protectedResult = "HTTP \(statusCode)\nRefresh token changed: \(refreshTokenChanged)\n\(body)"
            scenarioStatus = (200..<300).contains(statusCode) && refreshTokenChanged
                ? "refresh_test_passed"
                : "refresh_test_failed"
        } catch {
            protectedResult = String(describing: error)
            scenarioStatus = "refresh_test_failed"
        }
    }

    private func resetRefreshSimulation() async {
        isTestingRefresh = true
        scenarioStatus = "refresh_reset_requested"
        defer { isTestingRefresh = false }

        let apiURL = E2ESupport.apiURL ?? ExampleAppConfig.apiURL
        var request = URLRequest(url: apiURL.appendingPathComponent("test/refresh/reset"))
        request.httpMethod = "POST"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""

            refreshSimulationCompleted = false
            protectedResult = "HTTP \(statusCode)\n\(body)"
            scenarioStatus = (200..<300).contains(statusCode) ? "refresh_reset_complete" : "refresh_reset_failed"
        } catch {
            protectedResult = String(describing: error)
            scenarioStatus = "refresh_reset_failed"
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(red: 0.859, green: 0.882, blue: 0.918), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 20, x: 0, y: 10)
    }
}

private struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(label):")
                .fontWeight(.semibold)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct FlowButton: View {
    enum Style {
        case primary
        case secondary
        case compact
    }

    let title: String
    let style: Style
    let action: () -> Void

    init(_ title: String, style: Style = .primary, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .frame(maxWidth: style == .compact ? nil : .infinity)
                .padding(.vertical, style == .compact ? 8 : 12)
                .padding(.horizontal, style == .compact ? 12 : 16)
        }
        .buttonStyle(.plain)
        .background(style == .secondary ? Color(red: 0.898, green: 0.906, blue: 0.922) : Color(red: 0.067, green: 0.094, blue: 0.153))
        .foregroundStyle(style == .secondary ? Color(red: 0.067, green: 0.094, blue: 0.153) : Color.white)
        .clipShape(Capsule())
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
