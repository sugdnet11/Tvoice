import AVFAudio
import LiveKit
import SwiftUI
import UIKit

struct VideoCallView: View {
    @EnvironmentObject private var model: AppModel
    let credentials: VideoCallCredentials
    @StateObject private var call = LiveKitCallModel()
    @State private var speakerEnabled = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let track = call.remoteTrack {
                VideoTrackView(track: track, mirror: false)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 104))
                        .foregroundStyle(.white.opacity(0.72))
                    Text(call.errorMessage ?? "Ожидание абонента…")
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            LinearGradient(
                colors: [.black.opacity(0.68), .clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                VStack(spacing: 8) {
                    Label("Сквозное шифрование", systemImage: "lock.fill")
                        .font(.caption)
                    Text(credentials.peer.displayName)
                        .font(.title2.bold())
                    Text(call.connected ? duration(call.elapsedSeconds) : "Вызов…")
                        .font(.subheadline.monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.top, 10)
                Spacer()
                HStack(spacing: 15) {
                    control(
                        call.cameraEnabled ? "video.fill" : "video.slash.fill",
                        active: call.cameraEnabled
                    ) { Task { await call.toggleCamera() } }
                    control("phone.down.fill", color: .red) {
                        Task {
                            await call.disconnect()
                            await model.finishVideoCall()
                        }
                    }
                    control(speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", active: speakerEnabled) {
                        speakerEnabled.toggle()
                        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerEnabled ? .speaker : .none)
                    }
                    control(
                        call.microphoneEnabled ? "mic.fill" : "mic.slash.fill",
                        active: call.microphoneEnabled
                    ) { Task { await call.toggleMicrophone() } }
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 16)

            if let track = call.localTrack, call.cameraEnabled {
                VideoTrackView(track: track, mirror: true)
                    .frame(width: 112, height: 156)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.35)))
                    .shadow(radius: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 96)
                    .padding(.trailing, 14)
            }
        }
        .task { await call.connect(credentials) }
        .onDisappear { Task { await call.disconnect() } }
        .interactiveDismissDisabled()
    }

    private func control(
        _ symbol: String,
        color: Color = .black.opacity(0.5),
        active: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: 58, height: 58)
                .background(color, in: Circle())
        }
    }

    private func duration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VideoTrackView: UIViewRepresentable {
    let track: VideoTrack
    let mirror: Bool

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fill
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        view.track = track
    }
}

struct IncomingVideoCallView: View {
    @EnvironmentObject private var model: AppModel
    let invite: VideoCallInvite

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.tvoiceBlue, Color(red: 0.05, green: 0.18, blue: 0.22)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(spacing: 16) {
                Label("Сквозное шифрование", systemImage: "lock.fill")
                    .font(.caption)
                Spacer()
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 116))
                    .foregroundStyle(.white.opacity(0.85))
                Text(invite.peerName).font(.title2.bold())
                Text(invite.peerNumber).foregroundStyle(.white.opacity(0.75))
                Text("Входящий видеозвонок").font(.subheadline)
                Spacer()
                HStack(spacing: 78) {
                    callButton("phone.down.fill", color: .red) {
                        Task { await model.rejectIncomingVideoCall() }
                    }
                    callButton("video.fill", color: .green) {
                        Task { await model.answerIncomingVideoCall() }
                    }
                }
                .padding(.bottom, 42)
            }
            .foregroundStyle(.white)
            .padding()
        }
        .interactiveDismissDisabled()
    }

    private func callButton(_ symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(color, in: Circle())
        }
    }
}
