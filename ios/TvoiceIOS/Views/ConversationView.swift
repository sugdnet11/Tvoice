import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient
    let peer: Contact
    let initialConversation: Conversation?

    @State private var conversationID: String?
    @State private var messages = [ChatMessage]()
    @State private var draft = ""
    @State private var sending = false

    init(peer: Contact, initialConversation: Conversation? = nil) {
        self.peer = peer
        self.initialConversation = initialConversation
        _conversationID = State(initialValue: initialConversation?.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message, mine: message.sender.id == model.user?.id)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .onChange(of: messages.count) { _ in
                if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .navigationTitle(peer.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { model.errorMessage = "SIP-аудиодвижок iOS подключается на следующем этапе" } label: {
                    Image(systemName: "phone.fill")
                }
                Button { Task { await model.startVideoCall(peer: peer.sipNumber) } } label: {
                    Image(systemName: "video.fill")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await send() }
                } label: {
                    if sending { ProgressView() }
                    else { Image(systemName: "arrow.up.circle.fill").font(.title) }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .task {
            api.onChatChanged = { Task { await loadMessages() } }
            await prepare()
        }
        .onDisappear { api.onChatChanged = nil }
    }

    private func prepare() async {
        do {
            if conversationID == nil {
                conversationID = try await api.ensureConversation(peer: peer.sipNumber).id
            }
            await loadMessages()
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func loadMessages() async {
        guard let conversationID else { return }
        do {
            messages = try await api.messages(conversationID: conversationID)
            try? await api.markRead(conversationID: conversationID)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversationID else { return }
        sending = true
        draft = ""
        do {
            let message = try await api.sendMessage(conversationID: conversationID, text: text)
            messages.append(message)
        } catch {
            draft = text
            model.errorMessage = error.localizedDescription
        }
        sending = false
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 56) }
            VStack(alignment: .trailing, spacing: 3) {
                Text(message.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Text(time(message.createdAt)).font(.caption2)
                    if mine {
                        Image(systemName: receiptIcon)
                            .font(.caption2)
                            .foregroundStyle(message.status == .read ? Color.tvoiceBlue : Color.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(mine ? Color.tvoiceBlue.opacity(0.14) : Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            if !mine { Spacer(minLength: 56) }
        }
    }

    private var receiptIcon: String {
        message.status == .sent ? "checkmark" : "checkmark.circle.fill"
    }

    private func time(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
