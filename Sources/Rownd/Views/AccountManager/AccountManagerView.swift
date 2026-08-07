//
//  AccountManager.swift
//  RowndSDK
//
//  Created by Matt Hamann on 7/13/22.
//

import SwiftUI
import AnyCodable

struct AccountManager: View {

    @StateObject var appConfig = Rownd.getInstance().state().subscribe { $0.appConfig }
    @StateObject var userData = Rownd.getInstance().state().subscribe { $0.user.data }
    @State var userIsLoading = Rownd.getInstance().state().subscribe { $0.user.isLoading }

    @State private var editingUser: [String: AnyCodable] = [:]

    private func binding(for key: String) -> Binding<String> {
        return .init(
            get: { userData.current[key]?.value as? String ?? ""},
            set: { editingUser[key] = AnyCodable.init($0) })
    }

    var body: some View {
        VStack {
            ScrollView {
                ForEach(appConfig.current.schema?.keys.sorted() ?? [], id: \.self) { field in
                    VStack(alignment: .leading) {
                        Text(appConfig.current.schema?[field]?.displayName ?? field)
                            .bold()
                        TextField(appConfig.current.schema?[field]?.displayName ?? field, text: binding(for: field))
                            .overlay(VStack {
                                Divider().offset(x: 0, y: 15)
                            })
                    }
                    .padding(.vertical, 7.0)

                }
                .padding(.horizontal, 5.0)
            }
            Button(action: {
                let mergedData = editingUser.merging(userData.current) { (current, _) in current }
                Context.currentContext.store.dispatch(
                    UserData.save(editingUser, optimisticData: mergedData)
                )
            }) {
                Text(userIsLoading.current ? "Saving..." : "Save")
            }
            .opacity(userIsLoading.current ? 0.5 : 1.0)

        }
        .padding()
    }
}

struct AccountManager_Previews: PreviewProvider {
    static var previews: some View {
        AccountManager()
    }
}
