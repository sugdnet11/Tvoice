import SwiftUI

struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient
    @State private var contacts = [Contact]()
    @State private var search = ""
    @State private var loading = false

    private var filtered: [Contact] {
        guard !search.isEmpty else { return contacts }
        return contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.sipNumber.contains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { contact in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.tvoiceBlue.opacity(0.13))
                        .frame(width: 44, height: 44)
                        .overlay(Text(initials(contact.displayName)).font(.headline).foregroundStyle(.tvoiceBlue))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(contact.displayName).fontWeight(.medium)
                        Text(contact.sipNumber).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    NavigationLink {
                        ConversationView(peer: contact)
                    } label: {
                        Image(systemName: "message.fill")
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await model.startVideoCall(peer: contact.sipNumber) }
                    } label: {
                        Image(systemName: "video.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Tvoice")
            .searchable(text: $search, prompt: "Имя или номер")
            .refreshable { await load() }
            .task { if contacts.isEmpty { await load() } }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { contacts = try await api.contacts() }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func initials(_ value: String) -> String {
        value.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
