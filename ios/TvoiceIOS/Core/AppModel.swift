import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var user: TvoiceUser?
    @Published var isRestoring = true
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var activeVideoCall: VideoCallCredentials?

    let api: ChatAPIClient
    let callKit: CallKitManager
    private var cancellables = Set<AnyCancellable>()

    init(api: ChatAPIClient = ChatAPIClient(), callKit: CallKitManager = CallKitManager()) {
        self.api = api
        self.callKit = callKit
        bindCalls()
    }

    var isAuthenticated: Bool { user != nil }

    func restoreSession() async {
        defer { isRestoring = false }
        guard let credentials = KeychainStore.load() else { return }
        do {
            let response = try await api.login(
                sipNumber: credentials.sipNumber,
                password: credentials.password
            )
            user = response.user
        } catch {
            KeychainStore.clear()
            errorMessage = error.localizedDescription
        }
    }

    func login(number: String, password: String) async {
        let normalized = number.filter { $0.isNumber || "*#+".contains($0) }
        guard !normalized.isEmpty, !password.isEmpty else {
            errorMessage = "Введите логин и пароль"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await api.login(sipNumber: normalized, password: password)
            try KeychainStore.save(StoredCredentials(sipNumber: normalized, password: password))
            user = response.user
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        api.logout()
        KeychainStore.clear()
        user = nil
        activeVideoCall = nil
    }

    func startVideoCall(peer: String) async {
        do {
            let credentials = try await api.startVideoCall(peer: peer)
            activeVideoCall = credentials
            callKit.reportOutgoing(callID: credentials.callId, peer: credentials.peer.displayName, video: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func answerIncomingVideoCall() async {
        guard let invite = api.incomingVideoCall else { return }
        do {
            activeVideoCall = try await api.answerVideoCall(callID: invite.id)
            api.clearIncomingCall(invite.id)
        } catch {
            errorMessage = error.localizedDescription
            callKit.end(callID: invite.id)
        }
    }

    func rejectIncomingVideoCall() async {
        guard let invite = api.incomingVideoCall else { return }
        await api.rejectVideoCall(callID: invite.id)
        callKit.end(callID: invite.id)
    }

    func finishVideoCall() async {
        guard let call = activeVideoCall else { return }
        await api.endVideoCall(callID: call.callId)
        callKit.end(callID: call.callId)
        activeVideoCall = nil
    }

    private func bindCalls() {
        api.$incomingVideoCall
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] invite in
                self?.callKit.reportIncoming(
                    callID: invite.id,
                    peer: invite.peerName,
                    video: true
                )
            }
            .store(in: &cancellables)

        callKit.onAnswer = { [weak self] _ in
            Task { @MainActor in await self?.answerIncomingVideoCall() }
        }
        callKit.onEnd = { [weak self] callID in
            Task { @MainActor in
                guard let self else { return }
                if self.api.incomingVideoCall?.id == callID {
                    await self.rejectIncomingVideoCall()
                } else if self.activeVideoCall?.callId == callID {
                    await self.finishVideoCall()
                }
            }
        }
        api.onVideoCallEnded = { [weak self] callID, _ in
            guard self?.activeVideoCall?.callId == callID else { return }
            self?.activeVideoCall = nil
            self?.callKit.end(callID: callID)
        }
    }
}
