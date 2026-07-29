import SwiftUI

struct ChatsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient
    @State private var conversations = [Conversation]()
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List(conversations) { conversation in
                NavigationLink {
                    ConversationView(peer: conversation.peer, initialConversation: conversation)
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.tvoiceBlue.opacity(0.13))
                            .frame(width: 48, height: 48)
                            .overlay(Image(systemName: "person.fill").foregroundStyle(.tvoiceBlue))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversation.peer.displayName).fontWeight(.semibold)
                            Text(conversation.lastMessage?.body ?? "Начать диалог")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(conversation.peer.sipNumber)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if loading { ProgressView() }
                else if conversations.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "message")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Нет диалогов").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Чаты")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Circle()
                        .fill(api.isConnected ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                        .accessibilityLabel(api.isConnected ? "Чат подключён" : "Чат подключается")
                }
            }
            .refreshable { await load() }
            .task {
                api.onChatChanged = { Task { await load() } }
                await load()
            }
            .onDisappear { api.onChatChanged = nil }
        }
    }

    private func load() async {
        loading = conversations.isEmpty
        defer { loading = false }
        do { conversations = try await api.conversations() }
        catch { model.errorMessage = error.localizedDescription }
    }
}
