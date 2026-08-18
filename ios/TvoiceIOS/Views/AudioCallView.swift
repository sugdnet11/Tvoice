import SwiftUI

struct AudioCallView: View {
    @EnvironmentObject private var model: AppModel
    let peer: String
    @State private var elapsed = 0
    @State private var isMuted = false
    @State private var isSpeaker = false
    @State private var conferenceRoom = ""
    @State private var showingConference = false
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.tvoiceNavy.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Avatar and Contact Name
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.tvoiceBlue)
                            .frame(width: 110, height: 110)
                        Text(peer.prefix(2).uppercased())
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Color.tvoiceBlue.opacity(0.4), radius: 12, x: 0, y: 6)

                    Text(peer)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)

                    Text(callStatusText)
                        .font(.headline)
                        .foregroundStyle(Color.tvoiceGreen)
                }

                Spacer()

                // Call Controls
                if case .incoming = model.sipEngine.callState {
                    // Incoming call controls: Decline vs Accept
                    HStack(spacing: 48) {
                        // Reject / Decline Button
                        Button {
                            model.rejectIncomingAudioCall()
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 72, height: 72)
                                    .overlay(
                                        Image(systemName: "phone.down.fill")
                                            .font(.title)
                                            .foregroundStyle(.white)
                                    )
                                Text("Отклонить")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }

                        // Accept Button
                        Button {
                            Task { await model.answerIncomingAudioCall() }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 72, height: 72)
                                    .overlay(
                                        Image(systemName: "phone.fill")
                                            .font(.title)
                                            .foregroundStyle(.white)
                                    )
                                Text("Принять")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.bottom, 48)
                } else {
                    VStack(spacing: 28) {
                        HStack(spacing: 14) {
                            Button {
                                isMuted.toggle()
                                model.sipEngine.setMuted(isMuted)
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(isMuted ? Color.white : Color.white.opacity(0.18))
                                        .frame(width: 56, height: 56)
                                        .overlay(
                                            Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                                                .font(.title3)
                                                .foregroundStyle(isMuted ? Color.tvoiceNavy : Color.white)
                                        )
                                    Text(isMuted ? "Выкл." : "Микрофон")
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .frame(width: 72)
                            }

                            Button {
                                model.toggleAudioHold()
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(model.sipEngine.isCallHeld ? Color.white : Color.white.opacity(0.18))
                                        .frame(width: 56, height: 56)
                                        .overlay(
                                            Image(systemName: model.sipEngine.isCallHeld ? "play.fill" : "pause.fill")
                                                .font(.title3)
                                                .foregroundStyle(model.sipEngine.isCallHeld ? Color.tvoiceNavy : Color.white)
                                        )
                                    Text(model.sipEngine.isCallHeld ? "Вернуть" : "Удержать")
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .frame(width: 72)
                            }

                            Button {
                                showingConference = true
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.white.opacity(0.18))
                                        .frame(width: 56, height: 56)
                                        .overlay(
                                            Image(systemName: "person.3.fill")
                                                .font(.title3)
                                                .foregroundStyle(.white)
                                        )
                                    Text("Конф.")
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .frame(width: 72)
                            }

                            Button {
                                isSpeaker.toggle()
                                model.sipEngine.toggleSpeaker(enabled: isSpeaker)
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(isSpeaker ? Color.white : Color.white.opacity(0.18))
                                        .frame(width: 56, height: 56)
                                        .overlay(
                                            Image(systemName: isSpeaker ? "speaker.wave.3.fill" : "speaker.slash.fill")
                                                .font(.title3)
                                                .foregroundStyle(isSpeaker ? Color.tvoiceNavy : Color.white)
                                        )
                                    Text(isSpeaker ? "Динамик" : "Слуховой")
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .frame(width: 72)
                            }
                        }

                        Button {
                            timer?.invalidate()
                            model.finishAudioCall()
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 78, height: 78)
                                    .overlay(
                                        Image(systemName: "phone.down.fill")
                                            .font(.title)
                                            .foregroundStyle(.white)
                                    )
                                    .shadow(color: Color.red.opacity(0.4), radius: 10, x: 0, y: 5)
                                Text("Завершить")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.bottom, 48)
                }
            }
        }
        .onAppear {
            startTimerIfNeeded()
        }
        .onChange(of: model.sipEngine.callState) { newState in
            if case .connected = newState {
                elapsed = 0
                startTimerIfNeeded()
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
        .alert("Конференция", isPresented: $showingConference) {
            TextField("Номер комнаты", text: $conferenceRoom)
                .keyboardType(.phonePad)
            Button("Подключить") {
                let room = conferenceRoom
                conferenceRoom = ""
                Task { await model.startAudioConference(room: room) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Введите номер конференц-комнаты FreePBX.")
        }
    }

    private func startTimerIfNeeded() {
        guard case .connected = model.sipEngine.callState else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsed += 1
        }
    }

    private var callStatusText: String {
        switch model.sipEngine.callState {
        case .incoming:
            return "Входящий вызов…"
        case .calling:
            return "Вызов"
        case .connected:
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            return String(format: "%02d:%02d", minutes, seconds)
        case .failed(let reason):
            return "Ошибка: \(reason)"
        case .idle:
            return "Звонок завершён"
        }
    }
}
