import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient

    var body: some View {
        Group {
            if model.isRestoring {
                ProgressView("Подключение Tvoice…")
            } else if model.isAuthenticated {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .tint(.tvoiceBlue)
        .alert("Tvoice", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .fullScreenCover(item: $model.activeVideoCall) { credentials in
            VideoCallView(credentials: credentials)
        }
        .fullScreenCover(isPresented: Binding(
            get: { api.incomingVideoCall != nil && model.activeVideoCall == nil },
            set: { _ in }
        )) {
            if let invite = api.incomingVideoCall {
                IncomingVideoCallView(invite: invite)
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            ContactsView()
                .tabItem { Label("Контакты", systemImage: "person.2.fill") }
            CallsView()
                .tabItem { Label("Звонки", systemImage: "phone.fill") }
            ChatsView()
                .tabItem { Label("Чаты", systemImage: "message.fill") }
            AccountView()
                .tabItem { Label("Аккаунт", systemImage: "person.crop.circle.fill") }
        }
    }
}

extension Color {
    static let tvoiceBlue = Color(red: 26 / 255, green: 76 / 255, blue: 221 / 255)
}
