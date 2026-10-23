import Foundation
import SwiftUI

struct AppIssue: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

struct ErrorLogView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recording, model and provider failures appear here without interrupting your work.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear list") { store.clearErrorLog() }.disabled(store.errorEvents.isEmpty)
            }
            Text("This session only · up to 100 recent issues. Transcripts and recovery audio remain in History.")
                .font(.caption).foregroundStyle(.secondary)
            if store.errorEvents.isEmpty {
                Label("No errors this session", systemImage: "checkmark.circle").padding()
            }
            ForEach(store.errorEvents.reversed()) { issue in
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    Text(issue.message).textSelection(.enabled)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
