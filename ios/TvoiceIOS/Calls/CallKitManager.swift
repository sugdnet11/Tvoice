import AVFAudio
import CallKit
import Foundation

final class CallKitManager: NSObject, CXProviderDelegate {
    var onAnswer: ((String) -> Void)?
    var onEnd: ((String) -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var ids = [String: UUID]()

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

    func reportIncoming(callID: String, peer: String, video: Bool) {
        let uuid = UUID()
        ids[callID] = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peer)
        update.localizedCallerName = peer
        update.hasVideo = video
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if error != nil { self?.ids.removeValue(forKey: callID) }
        }
    }

    func reportOutgoing(callID: String, peer: String, video: Bool) {
        let uuid = UUID()
        ids[callID] = uuid
        let handle = CXHandle(type: .generic, value: peer)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = video
        controller.request(CXTransaction(action: action)) { _ in }
    }

    func end(callID: String) {
        guard let uuid = ids.removeValue(forKey: callID) else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let callID = callID(for: action.callUUID) else {
            action.fail()
            return
        }
        onAnswer?(callID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let callID = callID(for: action.callUUID) else {
            action.fulfill()
            return
        }
        ids.removeValue(forKey: callID)
        onEnd?(callID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        try? audioSession.setCategory(.playAndRecord, mode: .videoChat, options: [.allowBluetooth, .defaultToSpeaker])
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}

    func providerDidReset(_ provider: CXProvider) {
        ids.removeAll()
    }

    private func callID(for uuid: UUID) -> String? {
        ids.first(where: { $0.value == uuid })?.key
    }
}
