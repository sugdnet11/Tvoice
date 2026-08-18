import AVFoundation
import Foundation
import LiveKit

struct RemoteVideoFeed: Identifiable {
    let id: String
    let participantID: String
    let participantName: String
    let track: VideoTrack
    let isSpeaking: Bool
    let audioLevel: Float
}

@MainActor
final class LiveKitCallModel: NSObject, ObservableObject, RoomDelegate, ParticipantDelegate {
    @Published private(set) var remoteVideos = [RemoteVideoFeed]()
    @Published private(set) var localTrack: VideoTrack?
    @Published private(set) var connected = false
    @Published private(set) var errorMessage: String?
    @Published var microphoneEnabled = true
    @Published var cameraEnabled = true
    @Published var elapsedSeconds = 0

    private static let cameraCaptureOptions = CameraCaptureOptions(
        position: .front,
        dimensions: .h1080_169,
        fps: 30
    )
    private static let videoPublishOptions = VideoPublishOptions(
        encoding: VideoEncoding(maxBitrate: 5_000_000, maxFps: 30),
        simulcast: true,
        preferredCodec: .h264,
        preferredBackupCodec: .vp8
    )

    private(set) lazy var room = Room(
        delegate: self,
        roomOptions: RoomOptions(
            defaultCameraCaptureOptions: Self.cameraCaptureOptions,
            defaultVideoPublishOptions: Self.videoPublishOptions,
            adaptiveStream: false,
            dynacast: true,
            reportRemoteTrackStatistics: true
        )
    )
    private var timerTask: Task<Void, Never>?

    func connect(_ credentials: VideoCallCredentials) async {
        do {
            try await room.connect(url: credentials.url, token: credentials.token)
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(
                enabled: true,
                captureOptions: Self.cameraCaptureOptions,
                publishOptions: Self.videoPublishOptions
            )
            await refreshExistingVideoTracks()
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
        try? await room.localParticipant.setCamera(
            enabled: cameraEnabled,
            captureOptions: Self.cameraCaptureOptions,
            publishOptions: Self.videoPublishOptions
        )
    }

    func disconnect() async {
        timerTask?.cancel()
        timerTask = nil
        await room.disconnect()
        remoteVideos = []
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
        didPublishTrack publication: RemoteTrackPublication
    ) {
        Task { @MainActor in await self.configureRemoteVideo(publication, participant: participant) }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        Task { @MainActor in await self.configureRemoteVideo(publication, participant: participant) }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didUnsubscribeTrack publication: RemoteTrackPublication
    ) {
        Task { @MainActor in self.removeRemoteVideo(publication.sid) }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didUnpublishTrack publication: RemoteTrackPublication
    ) {
        Task { @MainActor in self.removeRemoteVideo(publication.sid) }
    }

    nonisolated func room(
        _ room: Room,
        participant: Participant,
        trackPublication: TrackPublication,
        didUpdateIsMuted isMuted: Bool
    ) {
        Task { @MainActor in
            if isMuted {
                self.removeRemoteVideo(trackPublication.sid)
            } else if let publication = trackPublication as? RemoteTrackPublication {
                guard let remoteParticipant = participant as? RemoteParticipant else { return }
                await self.configureRemoteVideo(publication, participant: remoteParticipant)
            }
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.observeRemoteParticipant(participant)
            self.markConnected()
            await self.refreshExistingVideoTracks()
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            participant.remove(delegate: self)
            let participantID = self.remoteParticipantID(participant)
            self.remoteVideos.removeAll { $0.participantID == participantID }
            self.refreshRemoteVideosSnapshot()
        }
    }

    nonisolated func participant(_ participant: Participant, didUpdateIsSpeaking isSpeaking: Bool) {
        Task { @MainActor in
            guard let remoteParticipant = participant as? RemoteParticipant else { return }
            self.updateSpeakingState(for: remoteParticipant)
        }
    }

    private func refreshExistingVideoTracks() async {
        for participant in room.remoteParticipants.values {
            observeRemoteParticipant(participant)
            for publication in participant.videoTracks.compactMap({ $0 as? RemoteTrackPublication }) {
                await configureRemoteVideo(publication, participant: participant)
            }
        }
    }

    private func configureRemoteVideo(_ publication: RemoteTrackPublication, participant: RemoteParticipant) async {
        guard publication.kind == .video else { return }

        do {
            try await publication.set(subscribed: true)
            try await publication.set(enabled: true)
            try await publication.set(videoQuality: .high)
            try await publication.set(preferredDimensions: .h1080_169)
            try await publication.set(preferredFPS: 30)
        } catch {
            print("Failed to configure remote video track:", error.localizedDescription)
        }

        guard let track = publication.track as? VideoTrack else { return }
        let feed = RemoteVideoFeed(
            id: publication.sid.stringValue,
            participantID: remoteParticipantID(participant),
            participantName: participant.name ?? participant.identity?.stringValue ?? "Абонент",
            track: track,
            isSpeaking: participant.isSpeaking,
            audioLevel: participant.audioLevel
        )
        if let index = remoteVideos.firstIndex(where: { $0.id == feed.id }) {
            remoteVideos[index] = feed
        } else {
            remoteVideos.append(feed)
        }
        remoteVideos.sort { $0.participantName.localizedStandardCompare($1.participantName) == .orderedAscending }
        markConnected()
    }

    private func removeRemoteVideo(_ sid: Track.Sid) {
        remoteVideos.removeAll { $0.id == sid.stringValue }
    }

    private func refreshRemoteVideosSnapshot() {
        var feeds = [RemoteVideoFeed]()
        for participant in room.remoteParticipants.values {
            observeRemoteParticipant(participant)
            for publication in participant.videoTracks.compactMap({ $0 as? RemoteTrackPublication }) {
                guard let track = publication.track as? VideoTrack, !publication.isMuted else { continue }
                feeds.append(RemoteVideoFeed(
                    id: publication.sid.stringValue,
                    participantID: remoteParticipantID(participant),
                    participantName: participant.name ?? participant.identity?.stringValue ?? "Абонент",
                    track: track,
                    isSpeaking: participant.isSpeaking,
                    audioLevel: participant.audioLevel
                ))
            }
        }
        remoteVideos = feeds.sorted {
            $0.participantName.localizedStandardCompare($1.participantName) == .orderedAscending
        }
    }

    private func observeRemoteParticipant(_ participant: RemoteParticipant) {
        participant.add(delegate: self)
    }

    private func updateSpeakingState(for participant: RemoteParticipant) {
        let participantID = remoteParticipantID(participant)
        remoteVideos = remoteVideos.map { feed in
            guard feed.participantID == participantID else { return feed }
            return RemoteVideoFeed(
                id: feed.id,
                participantID: feed.participantID,
                participantName: feed.participantName,
                track: feed.track,
                isSpeaking: participant.isSpeaking,
                audioLevel: participant.audioLevel
            )
        }
    }

    private func remoteParticipantID(_ participant: RemoteParticipant) -> String {
        participant.identity?.stringValue ?? participant.sid?.stringValue ?? participant.name ?? "unknown"
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
