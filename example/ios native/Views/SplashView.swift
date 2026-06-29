//
//  SplashView.swift
//  ios native
//
//  Created by Matt Hamann on 5/23/23.
//

import SwiftUI
import Rownd
import Lottie

struct SplashView: View {
    @StateObject var rowndState = Rownd.getInstance().state().subscribe { $0 }
    @StateObject var authState = Rownd.getInstance().state().subscribe { $0.auth }

    var body: some View {
        VStack {
            Spacer()

            Text("Welcome to Lndmarks")
                .font(.title)

            if !rowndState.current.isInitialized || authState.current.isLoading {
                ProgressView()
                Spacer()
            }

            if rowndState.current.isInitialized && !authState.current.isAuthenticatedWithUserData {
                Spacer()
                VStack(spacing: 20) {
                    Button("Sign up as a guest", action: {
                        Rownd.requestSignIn(with: .guest)
                    })
                    .foregroundColor(.white)
                    .padding()
                    .background(Color(red: 0, green: 0.2, blue: 0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 20.0, style: .continuous))

                    Button("Sign in with an existing account", action: {
                        Rownd.requestSignIn()
                    })
                }
                .padding(.bottom, 25)
            }
        }
        .animation(.easeIn, value: rowndState.current.isInitialized)
        .transition(.slide)
    }
}

struct SplashView_Previews: PreviewProvider {
    static var previews: some View {
        SplashView()
    }
}
