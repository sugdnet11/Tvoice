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
    private var sipCallKitID: String?

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
        sipEngine.endCall()
        sipEngine.unregister()
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
            let callId = sipEngine.currentCallID ?? UUID().uuidString
            sipCallKitID = callId
            callKit.reportOutgoing(callID: callId, peer: peer, type: .sipAudio)
        } catch {
            activeAudioCallPeer = nil
            errorMessage = error.localizedDescription
        }
    }

    func answerIncomingAudioCall() {
        sipEngine.acceptCall()
        if let callID = sipCallKitID {
            callKit.reportConnected(callID: callID)
        }
    }

    func rejectIncomingAudioCall() {
        sipEngine.rejectCall()
        if let callID = sipCallKitID {
            callKit.end(callID: callID)
        }
    }

    func finishAudioCall() {
        sipEngine.endCall()
        if let callID = sipCallKitID {
            callKit.end(callID: callID)
        }
    }

    func toggleAudioHold() {
        sipEngine.toggleHold()
    }

    func startAudioConference(room: String) async {
        do {
            try await sipEngine.moveCurrentCallToConference(room: room)
            let callId = sipEngine.currentCallID ?? UUID().uuidString
            sipCallKitID = callId
            callKit.reportOutgoing(callID: callId, peer: room, type: .sipAudio)
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
        sipEngine.$callState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case let .incoming(peer):
                    self.activeAudioCallPeer = peer
                    guard self.sipCallKitID == nil else { return }
                    let callID = self.sipEngine.currentCallID ?? UUID().uuidString
                    self.sipCallKitID = callID
                    self.callKit.reportIncoming(callID: callID, peer: peer, type: .sipAudio)
                case let .connected(peer):
                    self.activeAudioCallPeer = peer
                    if let callID = self.sipCallKitID {
                        self.callKit.reportConnected(callID: callID)
                    }
                case .idle, .failed:
                    self.activeAudioCallPeer = nil
                    if let callID = self.sipCallKitID {
                        self.sipCallKitID = nil
                        self.callKit.end(callID: callID)
                    }
                case .calling:
                    break
                }
            }
            .store(in: &cancellables)

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

        callKit.onEnd = { [weak self] callID, type in
            Task { @MainActor in
                guard let self else { return }
                if type == .sipAudio {
                    self.sipEngine.endCall()
                } else if self.api.incomingVideoCall?.id == callID {
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
