//
//  InstantUsers.swift
//  Rownd
//
//  Created by Matt Hamann on 4/18/25.
//

import Combine

@MainActor
class InstantUsers {
    private let context: Context
    private let requestSignIn: @MainActor (RowndSignInOptions) -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        context: Context,
        requestSignIn: @escaping @MainActor (RowndSignInOptions) -> Void = Rownd.requestSignIn
    ) {
        self.context = context
        self.requestSignIn = requestSignIn
    }

    func tmpForceInstantUserConversionIfRequested() {
        if !Rownd.config.forceInstantUserConversion {
            return
        }

        let subscriber = context.store.subscribe {
            $0
        }
        let requestSignIn = requestSignIn
        subscriber.$current
            .map {
                (
                    $0.auth.isAuthenticated,
                    $0.user.authLevel
                )
            }
            .removeDuplicates(
                by: ==
            )
            .first {
                isAuthenticated,
                authLevel in
                isAuthenticated && authLevel == .instant
            }
            .sink {
                isAuthenticated,
                authLevel in

                var signInOptions = RowndSignInOptions()
                signInOptions.title = "Add a sign-in method"
                signInOptions.subtitle = "To make sure you can always access your account, please add a sign-in method."
                signInOptions.intent = .signUp
                requestSignIn(signInOptions)

                subscriber
                    .unsubscribe()
            }.store(
                in: &self.cancellables
            )
    }
}
