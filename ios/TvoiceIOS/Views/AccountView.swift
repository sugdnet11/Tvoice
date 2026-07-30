import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Circle()
                            .fill(Color.tvoiceBlue)
                            .frame(width: 58, height: 58)
                            .overlay(Image(systemName: "person.fill").foregroundStyle(.white).font(.title2))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.user?.displayName ?? "Tvoice").font(.headline)
                            Text(model.user?.sipNumber ?? "").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Подключения") {
                    LabeledContent("FreePBX", value: "\(AppConfig.sipHost):\(AppConfig.sipPort)")
                    LabeledContent("Чат", value: api.isConnected ? "Подключён" : "Подключение…")
                    LabeledContent("Видео", value: AppConfig.videoHost)
                }
                Section("Оформление") {
                    LabeledContent("Тема", value: "Системная")
                }
                Section {
                    Button("Выйти из аккаунта", role: .destructive) { model.logout() }
                }
            }
            .navigationTitle("Аккаунт")
        }
    }
}
