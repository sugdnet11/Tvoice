import Combine
import Foundation
import AVFoundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var user: TvoiceUser?
    @Published var isRestoring = true
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var activeVideoCall: VideoCallCredentials?
    @Published var activeAudioCallPeer: String?

    let api: ChatAPIClient
    let callKit: CallKitManager
    let sipEngine = NativeSipEngine()
    private var cancellables = Set<AnyCancellable>()

    init(api: ChatAPIClient? = nil, callKit: CallKitManager = CallKitManager()) {
        self.api = api ?? ChatAPIClient()
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
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
            sipEngine.register(sipNumber: credentials.sipNumber, password: credentials.password)
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
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
            sipEngine.register(sipNumber: normalized, password: password)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        api.logout()
        sipEngine.unregister()
        sipEngine.endCall()
        KeychainStore.clear()
        user = nil
        activeVideoCall = nil
        activeAudioCallPeer = nil
    }

    func startVideoCall(peer: String) async {
        do {
            LocalCallHistoryStore.saveCall(sipNumber: peer, displayName: peer, direction: "outgoing", isVideo: true)
            let credentials = try await api.startVideoCall(peer: peer)
            activeVideoCall = credentials
            callKit.reportOutgoing(callID: credentials.callId, peer: credentials.peer.displayName, type: .liveKitVideo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startAudioCall(peer: String) async {
        do {
            LocalCallHistoryStore.saveCall(sipNumber: peer, displayName: peer, direction: "outgoing", isVideo: false)
            activeAudioCallPeer = peer
            try await sipEngine.startAudioCall(peer: peer)
            let callId = UUID().uuidString
            callKit.reportOutgoing(callID: callId, peer: peer, type: .sipAudio)
        } catch {
            activeAudioCallPeer = nil
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
                    type: .liveKitVideo
                )
            }
            .store(in: &cancellables)

        callKit.onAnswer = { [weak self] _, type in
            Task { @MainActor in
                if type == .sipAudio {
                    self?.sipEngine.acceptCall()
                } else {
                    await self?.answerIncomingVideoCall()
                }
            }
        }

        callKit.onEnd = { [weak self] callID in
            Task { @MainActor in
                guard let self else { return }
                if self.activeVideoCall?.callId == callID {
                    await self.finishVideoCall()
                } else {
                    self.sipEngine.endCall()
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
