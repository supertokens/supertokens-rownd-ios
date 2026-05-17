//
//  ContentView.swift
//  ios native
//
//  Created by Matt Hamann on 6/10/22.
//

import SwiftUI
import Rownd
import Combine
import AnyCodable
import WidgetKit

struct ContentView: View {
    @StateObject var authState = Rownd.getInstance().state().subscribe { $0.auth }
    @StateObject var user = Rownd.getInstance().state().subscribe { $0.user.data }
    @StateObject var state = Rownd.getInstance().state().subscribe { $0 }

    @State var displayCryptSheet = false
    @State var presentEditName = false
    @State var firstName = ""
    @State var plainCryptText = ""
    @State var cipherCryptText = ""

    private var cancellables = Set<AnyCancellable>()

    init() {
//        self.user.$current.sink { u in
//            self.firstName = u["first_name"]?.value as? String ?? ""
//        }
//        .store(in: &cancellables)
        self.state.$current.sink { _ in
            WidgetCenter.shared.reloadAllTimelines()
        }
        .store(in: &cancellables)
    }

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some View {
        VStack {
            HStack {

                Button("Edit name") {
                    firstName = user.current["first_name"]?.value as? String ?? ""
                    presentEditName = true
                }
                    .sheet(isPresented: $presentEditName,
                        content: {
                        VStack {
                            Text("Update your name below.")
                            TextField("First name", text: $firstName)
                            HStack {
                                Button("Cancel", action: {
                                    presentEditName = false
                                })
                                Button("Save", action: {
                                    Rownd.user.set(field: "first_name", value: AnyCodable(firstName))
                                    presentEditName = false
                                })
                            }
                        }
                })

                Spacer()

                if authState.current.isAuthenticatedWithUserData {
                    Menu {
                        Button(action: {
                            Rownd.manageAccount()
                        }, label: {
                            Text((user.current["first_name"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "My account" )
                        })

                        Section {
                            Button(action: {
                                Rownd._refreshToken()
                            }, label: {
                                Text("Refresh token")
                            })

                            Button(action: {
                                displayCryptSheet = true
                            }, label: {
                                Text("Test encryption")
                            }).sheet(isPresented: $displayCryptSheet, content: {
                                VStack {
                                    VStack {
                                        Text("Plain text")
                                        TextEditor(text: $plainCryptText)
                                    }.padding()

                                    VStack {
                                        Text("Cipher text")
                                        TextEditor(text: $cipherCryptText)
                                    }.padding()

                                    HStack {
                                        Button(action: {
                                            do {
                                                let result = try Rownd.user.encrypt(plaintext: plainCryptText)
//                                                cipherCryptText = result
                                            } catch {
                                                cipherCryptText = String(describing: error)
                                            }
                                        }, label: {
                                            Text("Encrypt")
                                        })
                                        Spacer()
                                        Button(action: {
                                            do {
                                                let result = try Rownd.user.decrypt(ciphertext: cipherCryptText)
//                                                plainCryptText = result
                                            } catch {
                                                plainCryptText = String(describing: error)
                                            }
                                        }, label: {
                                            Text("Decrypt")
                                        })
                                    }
                                }
                            })
                        }

                        Section {
                            Button(action: {
                                Rownd.signOut()
                            }, label: {
                                Text("Sign out")
                            })
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                } else {
                    VStack {
                        Button(action: {
                            Rownd.requestSignIn(RowndSignInOptions(intent: .signUp))
                        }, label: {
                            Text("Sign in")
                        })

                        Button(action: {
                            Rownd.requestSignIn(
                                with: .googleId
                            )
                        }, label: {
                            Text("Sign in w/ Google")
                        })

                        Button(action: {
                            Rownd.requestSignIn(
                                with: .appleId,
                                signInOptions: RowndSignInOptions(
                                    intent: .signUp
                                )
                            )
                        }, label: {
                            Text("Sign in w/ Apple")
                        })
                    }
                }
            }
            .padding(.horizontal)

            LandmarkList()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
