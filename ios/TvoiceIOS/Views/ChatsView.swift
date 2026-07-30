import SwiftUI

struct ChatsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient
    @State private var conversations = [Conversation]()
    @State private var loading = true
    @State private var search = ""
    @State private var showNewChatModal = false
    @State private var selectedPeer: Contact?

    private var filtered: [Conversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter {
            $0.peer.displayName.localizedCaseInsensitiveContains(search) || $0.peer.sipNumber.contains(search)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    // Header title matching Android / design screenshot
                    HStack {
                        Text("Чаты")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(Color.tvoiceNavy)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                    // Search Bar
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.secondary)
                        TextField("Поиск", text: $search)
                            .font(.body)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .cornerRadius(14)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                    // Conversations List
                    if loading && conversations.isEmpty {
                        Spacer()
                        ProgressView()
                        Spacer()
                    } else if conversations.isEmpty {
                        Spacer()
                        VStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(Color.tvoiceBlue.opacity(0.1))
                                    .frame(width: 96, height: 96)
                                Image(systemName: "message.fill")
                                    .font(.system(size: 42))
                                    .foregroundStyle(Color.tvoiceBlue)
                            }
                            Text("Сообщений пока нет")
                                .font(.title3.bold())
                                .foregroundStyle(Color.tvoiceNavy)
                            Text("Начните чат по SIP-номеру абонента")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(.horizontal, 32)
                        .multilineTextAlignment(.center)
                        Spacer()
                    } else {
                        List(filtered) { conversation in
                            NavigationLink {
                                ConversationView(peer: conversation.peer, initialConversation: conversation)
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack(alignment: .bottomTrailing) {
                                        Circle()
                                            .fill(Color.tvoiceBlue)
                                            .frame(width: 52, height: 52)
                                            .overlay(
                                                Text("T7")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundStyle(.white)
                                            )
                                        Circle()
                                            .fill(Color.tvoiceGreen)
                                            .frame(width: 14, height: 14)
                                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(conversation.peer.displayName)
                                            .font(.headline)
                                            .foregroundStyle(Color.tvoiceNavy)
                                        Text(conversation.lastMessage?.body ?? "Начать диалог")
                                            .font(.subheadline)
                                            .foregroundStyle(Color.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if let lastMessage = conversation.lastMessage {
                                        Text(formattedTime(lastMessage.createdAt))
                                            .font(.caption)
                                            .foregroundStyle(Color.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.plain)
                        .refreshable { await load() }
                    }
                }

                // Floating Action Button for New Chat matching Android / design screenshot
                Button {
                    showNewChatModal = true
                } label: {
                    Circle()
                        .fill(Color.tvoiceBlue)
                        .frame(width: 60, height: 60)
                        .overlay(
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        )
                        .shadow(color: Color.tvoiceBlue.opacity(0.4), radius: 12, x: 0, y: 6)
                }
                .padding(.trailing, 24)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .sheet(isPresented: $showNewChatModal) {
                NewChatSheetView(isPresented: $showNewChatModal) { contact in
                    selectedPeer = contact
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedPeer != nil },
                set: { if !$0 { selectedPeer = nil } }
            )) {
                if let peer = selectedPeer {
                    ConversationView(peer: peer)
                }
            }
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

    private func formattedTime(_ isoString: String?) -> String {
        guard let isoString = isoString else { return "" }
        if isoString.count >= 16 {
            let start = isoString.index(isoString.startIndex, offsetBy: 11)
            let end = isoString.index(isoString.startIndex, offsetBy: 16)
            return String(isoString[start..<end])
        }
        return isoString
    }
}

struct NewChatSheetView: View {
    @Binding var isPresented: Bool
    let onSelect: (Contact) -> Void

    @EnvironmentObject private var api: ChatAPIClient
    @State private var searchText = ""
    @State private var contacts = [Contact]()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Новый чат")
                        .font(.title2.bold())
                        .foregroundStyle(Color.tvoiceNavy)
                    
                    TextField("Поиск или номер абонента", text: $searchText)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemFill))
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                List(contacts.filter { searchText.isEmpty || $0.displayName.localizedCaseInsensitiveContains(searchText) || $0.sipNumber.contains(searchText) }) { contact in
                    Button {
                        isPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onSelect(contact)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(Color.tvoiceBlue)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Text("T7")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.white)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.displayName)
                                    .font(.headline)
                                    .foregroundStyle(Color.tvoiceNavy)
                                Text(contact.sipNumber)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)

                Button("ЗАКРЫТЬ") {
                    isPresented = false
                }
                .font(.headline)
                .foregroundStyle(Color.tvoiceBlue)
                .padding(.bottom, 8)
            }
            .padding(.top, 20)
            .task {
                do { contacts = try await api.contacts() }
                catch { }
            }
        }
    }
}


