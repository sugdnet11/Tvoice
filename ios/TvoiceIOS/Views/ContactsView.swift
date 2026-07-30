import SwiftUI

struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient
    @State private var contacts = [Contact]()
    @State private var search = ""
    @State private var loading = false

    @State private var showAddContact = false

    private var filtered: [Contact] {
        guard !search.isEmpty else { return contacts }
        return contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.sipNumber.contains(search)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    // Header title
                    HStack {
                        Text("Контакты")
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

                    // Contacts List with T7 avatars and status
                    if loading && contacts.isEmpty {
                        Spacer()
                        ProgressView()
                        Spacer()
                    } else {
                        List(filtered) { contact in
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(Color.tvoiceBlue)
                                    .frame(width: 48, height: 48)
                                    .overlay(
                                        Text("T7")
                                            .font(.system(size: 17, weight: .bold))
                                            .foregroundStyle(.white)
                                    )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contact.displayName)
                                        .font(.headline)
                                        .foregroundStyle(Color.tvoiceNavy)
                                    Text("Tvoice • доступен для чата")
                                        .font(.caption)
                                        .foregroundStyle(Color.tvoiceGreen)
                                }

                                Spacer()

                                Button {
                                    Task { await model.startAudioCall(peer: contact.sipNumber) }
                                } label: {
                                    Image(systemName: "phone.fill")
                                        .font(.body)
                                        .foregroundStyle(Color.tvoiceBlue)
                                        .padding(8)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    Task { await model.startVideoCall(peer: contact.sipNumber) }
                                } label: {
                                    Image(systemName: "video.fill")
                                        .font(.body)
                                        .foregroundStyle(Color.tvoiceBlue)
                                        .padding(8)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                        .listStyle(.plain)
                        .refreshable { await load() }
                    }
                }

                // Add contact Floating Button
                Button {
                    showAddContact = true
                } label: {
                    Circle()
                        .fill(Color.tvoiceBlue)
                        .frame(width: 60, height: 60)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.title.bold())
                                .foregroundStyle(.white)
                        )
                        .shadow(color: Color.tvoiceBlue.opacity(0.4), radius: 12, x: 0, y: 6)
                }
                .padding(.trailing, 24)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .task { if contacts.isEmpty { await load() } }
            .sheet(isPresented: $showAddContact) {
                AddContactSheetView { newContact in
                    contacts.insert(newContact, at: 0)
                }
                .environmentObject(model)
                .environmentObject(api)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { contacts = try await api.contacts() }
        catch { model.errorMessage = error.localizedDescription }
    }
}

struct AddContactSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient

    @State private var sipNumber = ""
    @State private var displayName = ""

    let onSave: (Contact) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Данные контакта") {
                    TextField("SIP номер (например, 70400)", text: $sipNumber)
                        .keyboardType(.numberPad)
                    TextField("Имя (необязательно)", text: $displayName)
                }
            }
            .navigationTitle("Новый контакт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        guard !sipNumber.isEmpty else { return }
                        let name = displayName.isEmpty ? sipNumber : displayName
                        let newContact = Contact(id: UUID().uuidString, sipNumber: sipNumber, displayName: name)
                        onSave(newContact)
                        dismiss()
                    }
                    .bold()
                    .disabled(sipNumber.isEmpty)
                }
            }
        }
    }
}

