import Combine
import Foundation
import AVFoundation
import UIKit

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
    private var sipCallKitReported = false
    private var audioCallDismissTask: Task<Void, Never>?
    private var audioCallStartCooldownTask: Task<Void, Never>?

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
        audioCallDismissTask?.cancel()
        audioCallDismissTask = nil
        audioCallStartCooldownTask?.cancel()
        audioCallStartCooldownTask = nil
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
        let normalizedPeer = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPeer.isEmpty else { return }
        guard activeAudioCallPeer == nil, audioCallStartCooldownTask == nil else { return }
        startAudioCallCooldown()
        do {
            LocalCallHistoryStore.saveCall(sipNumber: normalizedPeer, displayName: normalizedPeer, direction: "outgoing", isVideo: false)
            showAudioCall(peer: normalizedPeer)
            try await sipEngine.startAudioCall(peer: normalizedPeer)
            let callId = sipEngine.currentCallID ?? UUID().uuidString
            sipCallKitID = callId
            if UIApplication.shared.applicationState != .active {
                sipCallKitReported = true
                callKit.reportOutgoing(callID: callId, peer: normalizedPeer, type: .sipAudio)
            }
        } catch {
            activeAudioCallPeer = nil
            errorMessage = error.localizedDescription
        }
    }

    func answerIncomingAudioCall() async {
        await sipEngine.acceptCall()
        if sipCallKitReported, let callID = sipCallKitID {
            callKit.reportConnected(callID: callID)
        }
    }

    func rejectIncomingAudioCall() {
        sipEngine.rejectCall()
        if sipCallKitReported, let callID = sipCallKitID {
            callKit.end(callID: callID)
        }
        closeAudioCallUI()
    }

    func finishAudioCall() {
        sipEngine.endCall()
        if sipCallKitReported, let callID = sipCallKitID {
            callKit.end(callID: callID)
        }
        closeAudioCallUI()
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

    func addVideoParticipants(callID: String, rawNumbers: String) async -> String? {
        let numbers = rawNumbers
            .components(separatedBy: CharacterSet(charactersIn: ",; \n\t"))
        return await addVideoParticipants(callID: callID, peerNumbers: numbers)
    }

    func addVideoParticipants(callID: String, peerNumbers: [String]) async -> String? {
        var seen = Set<String>()
        let uniqueNumbers = peerNumbers
            .map { normalizedSipNumber($0) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        guard !uniqueNumbers.isEmpty else {
            return "Введите номер абонента"
        }

        do {
            let response = try await api.addVideoParticipants(callID: callID, peers: uniqueNumbers)
            if response.invited.isEmpty {
                let details = (response.missing + response.skipped).joined(separator: ", ")
                return details.isEmpty ? "Абоненты не добавлены" : "Абоненты не добавлены: \(details)"
            } else {
                return nil
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func normalizedSipNumber(_ value: String) -> String {
        value.filter { $0.isNumber || "*#+".contains($0) }
    }

    private func bindCalls() {
        sipEngine.$callState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case let .incoming(peer):
                    self.showAudioCall(peer: peer)
                    guard self.sipCallKitID == nil else { return }
                    let callID = self.sipEngine.currentCallID ?? UUID().uuidString
                    self.sipCallKitID = callID
                    if UIApplication.shared.applicationState != .active {
                        self.sipCallKitReported = true
                        self.callKit.reportIncoming(callID: callID, peer: peer, type: .sipAudio)
                    }
                case let .connected(peer):
                    self.showAudioCall(peer: peer)
                    if self.sipCallKitReported, let callID = self.sipCallKitID {
                        self.callKit.reportConnected(callID: callID)
                    }
                case .idle:
                    self.scheduleAudioCallDismiss(delay: 0.8)
                    let callID = self.sipCallKitID
                    self.sipCallKitID = nil
                    let wasReported = self.sipCallKitReported
                    self.sipCallKitReported = false
                    if wasReported, let callID {
                        self.callKit.end(callID: callID)
                    }
                case .failed:
                    self.scheduleAudioCallDismiss(delay: 2.0)
                    let callID = self.sipCallKitID
                    self.sipCallKitID = nil
                    let wasReported = self.sipCallKitReported
                    self.sipCallKitReported = false
                    if wasReported, let callID {
                        self.callKit.end(callID: callID)
                    }
                case let .calling(peer):
                    self.showAudioCall(peer: peer)
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
                    await self?.answerIncomingAudioCall()
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
        callKit.onAudioActivated = { [weak self] in
            Task { @MainActor in
                self?.sipEngine.handleSystemAudioSessionActivated()
            }
        }
        api.onVideoCallEnded = { [weak self] callID, _ in
            guard self?.activeVideoCall?.callId == callID else { return }
            self?.activeVideoCall = nil
            self?.callKit.end(callID: callID)
        }
    }

    private func showAudioCall(peer: String) {
        audioCallDismissTask?.cancel()
        audioCallDismissTask = nil
        activeAudioCallPeer = peer
    }

    private func scheduleAudioCallDismiss(delay: TimeInterval) {
        audioCallDismissTask?.cancel()
        audioCallDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                switch self.sipEngine.callState {
                case .incoming, .calling, .connected:
                    return
                case .idle, .failed:
                    self.activeAudioCallPeer = nil
                    self.audioCallDismissTask = nil
                }
            }
        }
    }

    private func closeAudioCallUI() {
        audioCallDismissTask?.cancel()
        audioCallDismissTask = nil
        activeAudioCallPeer = nil
        sipCallKitID = nil
        sipCallKitReported = false
    }

    private func startAudioCallCooldown() {
        audioCallStartCooldownTask?.cancel()
        audioCallStartCooldownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                self?.audioCallStartCooldownTask = nil
            }
        }
    }
}
