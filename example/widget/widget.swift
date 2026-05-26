//
//  widget.swift
//  widget
//
//  Created by Matt Hamann on 4/22/24.
//

import WidgetKit
import SwiftUI
import Rownd
import Combine

struct Provider: TimelineProvider {
    func initRownd () async -> RowndState {
        Rownd.config.apiUrl = "http://127.0.0.1:3137"
        Rownd.config.baseUrl = "https://staging.supertokens-rownd-hub.pages.dev"
        Rownd.config.deepLinkScheme = "rowndsupertokens"
        Rownd.config.appGroupPrefix = "group.rowndexample"
        return await Rownd.configure(
            appKey: "test_app_key",
            supertokens: RowndSuperTokensConfig(
                appName: "Rownd iOS All Authentication Methods",
                apiDomain: "http://127.0.0.1:3137",
                apiBasePath: "/auth"
            )
        )
    }

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), emoji: "❓")
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        Task {
            let rowndState = await initRownd()
            print(try? await Rownd.getAccessToken())
            var currentEmoji: String = "❓"
            if rowndState.auth.isAuthenticated == true {
                currentEmoji = "😁"
            } else if rowndState.auth.isAuthenticated == false {
                currentEmoji = "☹️"
            }
            let entry = SimpleEntry(date: Date(), emoji: currentEmoji)
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let rowndState = await initRownd()
            print(try? await Rownd.getAccessToken())

            var entries: [SimpleEntry] = []

            let currentDate = Date()
            var currentEmoji: String = "❓"
            if rowndState.auth.isAuthenticated == true {
                currentEmoji = "😁"
            } else if rowndState.auth.isAuthenticated == false {
                currentEmoji = "☹️"
            }

            let entry = SimpleEntry(date: currentDate, emoji: currentEmoji)
            entries.append(entry)

            let timeline = Timeline(entries: entries, policy: .atEnd)
            completion(timeline)
        }
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let emoji: String
}

struct widgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        VStack {
            Text("Time:")
            Text(entry.date, style: .time)

            Text("Signed in?")
            Text(entry.emoji)
        }
    }
}

struct widget: Widget {
    let kind: String = "widget"
    @StateObject var authState = Rownd.getInstance().state().subscribe { $0.auth }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                widgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                widgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Rownd")
        .description("Rownd auth state widget")

    }
}

#Preview(as: .systemSmall) {
    widget()
} timeline: {
    SimpleEntry(date: .now, emoji: "😀")
    SimpleEntry(date: .now, emoji: "🤩")
}
