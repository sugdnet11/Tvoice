import Foundation
import CallKit
import AVFoundation

enum CallType: Equatable {
    case sipAudio
    case liveKitVideo
}

final class CallKitManager: NSObject, CXProviderDelegate {
    var onAnswer: ((String, CallType) -> Void)?
    var onEnd: ((String, CallType) -> Void)?
    var onAudioActivated: (() -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var ids = [String: (uuid: UUID, type: CallType)]()

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "Tvoice")
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func reportIncoming(callID: String, peer: String, type: CallType) {
        let uuid = UUID()
        ids[callID] = (uuid: uuid, type: type)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peer)
        update.localizedCallerName = peer
        update.hasVideo = (type == .liveKitVideo)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if error != nil { self?.ids.removeValue(forKey: callID) }
        }
    }

    func reportOutgoing(callID: String, peer: String, type: CallType) {
        let uuid = UUID()
        ids[callID] = (uuid: uuid, type: type)
        let handle = CXHandle(type: .generic, value: peer)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = (type == .liveKitVideo)
        controller.request(CXTransaction(action: action)) { _ in }
    }

    func reportConnected(callID: String) {
        guard let entry = ids[callID] else { return }
        provider.reportOutgoingCall(with: entry.uuid, connectedAt: Date())
    }

    func answer(callID: String) {
        guard let entry = ids[callID] else { return }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: entry.uuid))) { _ in }
    }

    func end(callID: String) {
        guard let entry = ids.removeValue(forKey: callID) else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: entry.uuid))) { _ in }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let (callID, type) = callInfo(for: action.callUUID) else {
            action.fail()
            return
        }
        onAnswer?(callID, type)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let (callID, type) = callInfo(for: action.callUUID) else {
            action.fulfill()
            return
        }
        ids.removeValue(forKey: callID)
        onEnd?(callID, type)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        try? audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try? audioSession.overrideOutputAudioPort(.none)
        onAudioActivated?()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}

    func providerDidReset(_ provider: CXProvider) {
        ids.removeAll()
    }

    private func callInfo(for uuid: UUID) -> (callID: String, type: CallType)? {
        guard let match = ids.first(where: { $0.value.uuid == uuid }) else { return nil }
        return (callID: match.key, type: match.value.type)
    }
}
