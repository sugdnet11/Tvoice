import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient

    @State private var showSplash = true

    var body: some View {
        Group {
            if showSplash {
                SplashScreenView()
            } else if model.isRestoring {
                ProgressView("Подключение Tvoice…")
            } else if model.isAuthenticated {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .tint(Color.tvoiceBlue)
        .task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.easeInOut(duration: 0.4)) {
                showSplash = false
            }
        }
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
            get: {
                if case .incoming = model.sipEngine.callState { return true }
                if case .calling = model.sipEngine.callState { return true }
                if case .connected = model.sipEngine.callState { return true }
                return model.activeAudioCallPeer != nil
            },
            set: { if !$0 { model.activeAudioCallPeer = nil; model.sipEngine.endCall() } }
        )) {
            AudioCallView(peer: audioCallPeerName)
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

    private var audioCallPeerName: String {
        switch model.sipEngine.callState {
        case .incoming(let peer): return peer
        case .calling(let peer): return peer
        case .connected(let peer): return peer
        default: return model.activeAudioCallPeer ?? "Собеседник"
        }
    }
}

struct SplashScreenView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                // Partner logo (logonew.svg) and TOJIKTELECOM name at the top
                HStack(spacing: 12) {
                    Image("logonew")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 48)

                    Text("TOJIKTELECOM")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.85, green: 0.1, blue: 0.15)) // Partner brand red color matching logo
                }
                .padding(.top, 44)
                .padding(.horizontal, 24)
                
                Spacer()
                
                // Main welcome title in the center
                VStack(spacing: 8) {
                    Text("Tvoice")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.tvoiceNavy, Color.tvoiceBlue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Text("Добро пожаловать")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 24)
                
                Spacer()
                
                // Progress spinner at the bottom
                ProgressView()
                    .scaleEffect(1.2)
                    .padding(.bottom, 48)
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
    static let tvoiceBlue = Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255) // Vibrant iOS Brand Blue
    static let tvoiceNavy = Color(red: 10 / 255, green: 25 / 255, blue: 47 / 255)
    static let tvoiceGreen = Color(red: 40 / 255, green: 199 / 255, blue: 111 / 255)
    static let tvoiceBgLight = Color(red: 246 / 255, green: 248 / 255, blue: 252 / 255)
}
