import SwiftUI
import Rownd

struct ContentView: View {
    @StateObject var authState = Rownd.getInstance().state().subscribe { $0.auth }

    var body: some View {
        VStack {
            Text("Welcome to the Landmarks App Clip")
                .font(.largeTitle)
                .padding(.bottom, 50)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            if authState.current.isAuthenticated {
                Text("You are signed in")
                    .padding(.bottom, 20)
            } else {
                Text("You are not signed in")
                    .padding(.bottom, 20)
            }

            if authState.current.isAuthenticated {
                Button(action: {
                    // Add your action here
                    Rownd.signOut()
                }) {
                    Text("Sign out")
                        .font(.title)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.primary)
                        .foregroundColor(Color.accentColor)
                        .cornerRadius(10)
                }
            } else {
                Button(action: {
                    Rownd.requestSignIn()
                }) {
                    Text("Sign in")
                        .font(.title)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor)
                        .foregroundColor(Color.primary)
                        .cornerRadius(10)
                }
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
