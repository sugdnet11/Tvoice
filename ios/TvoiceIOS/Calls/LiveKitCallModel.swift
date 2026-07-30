import Foundation
import LiveKit

@MainActor
final class LiveKitCallModel: NSObject, ObservableObject, RoomDelegate {
    @Published private(set) var remoteTrack: VideoTrack?
    @Published private(set) var localTrack: VideoTrack?
    @Published private(set) var connected = false
    @Published private(set) var errorMessage: String?
    @Published var microphoneEnabled = true
    @Published var cameraEnabled = true
    @Published var elapsedSeconds = 0

    private(set) lazy var room = Room(delegate: self)
    private var timerTask: Task<Void, Never>?

    func connect(_ credentials: VideoCallCredentials) async {
        do {
            try await room.connect(url: credentials.url, token: credentials.token)
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(enabled: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleMicrophone() async {
        microphoneEnabled.toggle()
        try? await room.localParticipant.setMicrophone(enabled: microphoneEnabled)
    }

    func toggleCamera() async {
        cameraEnabled.toggle()
        try? await room.localParticipant.setCamera(enabled: cameraEnabled)
    }

    func disconnect() async {
        timerTask?.cancel()
        timerTask = nil
        await room.disconnect()
        remoteTrack = nil
        localTrack = nil
        connected = false
    }

    nonisolated func room(
        _ room: Room,
        participant: LocalParticipant,
        didPublishTrack publication: LocalTrackPublication
    ) {
        guard let track = publication.track as? VideoTrack else { return }
        Task { @MainActor in self.localTrack = track }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        guard let track = publication.track as? VideoTrack else { return }
        Task { @MainActor in
            self.remoteTrack = track
            self.markConnected()
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in self.markConnected() }
    }

    private func markConnected() {
        guard !connected else { return }
        connected = true
        elapsedSeconds = 0
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.elapsedSeconds += 1
            }
        }
    }
}
