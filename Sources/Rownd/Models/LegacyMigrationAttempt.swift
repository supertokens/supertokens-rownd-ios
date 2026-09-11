import Foundation

struct LegacyMigrationAttempt: Equatable {
    let context: Context
    var auth: AuthState
    let permit: SuperTokensSessionBridge.AuthOperationPermit
    let adoptionScope = SuperTokensSessionBridge.SessionAdoptionScope()

    @MainActor init(auth: AuthState) {
        self.context = Context.currentContext
        self.auth = auth
        self.permit = SuperTokensSessionBridge.captureAuthOperationPermit()
    }

    @MainActor var isCurrent: Bool {
        context === Context.currentContext
            && adoptionScope.isValid
            && SuperTokensSessionBridge.isAuthOperationPermitValid(permit)
            && context.store.state.auth.accessToken == auth.accessToken
            && context.store.state.auth.refreshToken == auth.refreshToken
    }

    func discardAdoption() async {
        adoptionScope.invalidate()
        await SuperTokensSessionBridge.discardSession(in: adoptionScope)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.context === rhs.context && lhs.permit == rhs.permit
            && lhs.auth.accessToken == rhs.auth.accessToken && lhs.auth.refreshToken == rhs.auth.refreshToken
    }
}
