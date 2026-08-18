import AVFAudio
import LiveKit
import SwiftUI
import UIKit

struct VideoCallView: View {
    @EnvironmentObject private var model: AppModel
    let credentials: VideoCallCredentials
    @StateObject private var call = LiveKitCallModel()
    @State private var speakerEnabled = true
    @State private var localPreviewPosition: CGPoint?
    @State private var showingAddParticipants = false
    @GestureState private var localPreviewDrag: CGSize = .zero

    private let localPreviewSize = CGSize(width: 112, height: 156)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteVideoGrid(feeds: call.remoteVideos, errorMessage: call.errorMessage)

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
                    control(speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", active: speakerEnabled) {
                        speakerEnabled.toggle()
                        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerEnabled ? .speaker : .none)
                    }
                    control(
                        call.microphoneEnabled ? "mic.fill" : "mic.slash.fill",
                        active: call.microphoneEnabled
                    ) { Task { await call.toggleMicrophone() } }
                    control("person.badge.plus", active: true) {
                        showingAddParticipants = true
                    }
                    control("phone.down.fill", color: .red) {
                        Task {
                            await call.disconnect()
                            await model.finishVideoCall()
                        }
                    }
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 16)

            GeometryReader { proxy in
                if let track = call.localTrack, call.cameraEnabled {
                    localPreview(track: track, in: proxy)
                }
            }
            .ignoresSafeArea()
        }
        .task { await call.connect(credentials) }
        .onDisappear {
            guard model.activeVideoCall?.callId != credentials.callId else { return }
            Task { await call.disconnect() }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showingAddParticipants) {
            AddVideoParticipantsSheet(
                callID: credentials.callId,
                currentPeerNumber: credentials.peer.sipNumber
            )
        }
    }

    private func localPreview(track: VideoTrack, in proxy: GeometryProxy) -> some View {
        let basePosition = localPreviewPosition ?? defaultLocalPreviewPosition(in: proxy)
        let draggedPosition = CGPoint(
            x: basePosition.x + localPreviewDrag.width,
            y: basePosition.y + localPreviewDrag.height
        )

        return VideoTrackView(track: track, mirror: true)
            .id(ObjectIdentifier(track))
            .frame(width: localPreviewSize.width, height: localPreviewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.35)))
            .shadow(radius: 8)
            .contentShape(Rectangle())
            .position(draggedPosition)
            .highPriorityGesture(
                DragGesture()
                    .updating($localPreviewDrag) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        let proposed = CGPoint(
                            x: basePosition.x + value.translation.width,
                            y: basePosition.y + value.translation.height
                        )
                        localPreviewPosition = clampedLocalPreviewPosition(proposed, in: proxy)
                    }
            )
    }

    private func defaultLocalPreviewPosition(in proxy: GeometryProxy) -> CGPoint {
        CGPoint(
            x: proxy.size.width - localPreviewSize.width / 2 - 14,
            y: proxy.safeAreaInsets.top + 96 + localPreviewSize.height / 2
        )
    }

    private func clampedLocalPreviewPosition(_ position: CGPoint, in proxy: GeometryProxy) -> CGPoint {
        let halfWidth = localPreviewSize.width / 2
        let halfHeight = localPreviewSize.height / 2

        return CGPoint(
            x: min(max(position.x, halfWidth), proxy.size.width - halfWidth),
            y: min(max(position.y, halfHeight), proxy.size.height - halfHeight)
        )
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

private struct RemoteVideoGrid: View {
    let feeds: [RemoteVideoFeed]
    let errorMessage: String?

    private let tileGap: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            if feeds.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feeds.count == 1, let feed = feeds.first {
                remoteTile(feed)
                    .ignoresSafeArea()
            } else {
                let frames = tileFrames(count: feeds.count, in: proxy)
                ZStack {
                    ForEach(Array(feeds.enumerated()), id: \.element.id) { index, feed in
                        if index < frames.count {
                            remoteTile(feed)
                                .frame(width: frames[index].width, height: frames[index].height)
                                .position(x: frames[index].midX, y: frames[index].midY)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 104))
                .foregroundStyle(.white.opacity(0.72))
            Text(errorMessage ?? "Ожидание абонента…")
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func remoteTile(_ feed: RemoteVideoFeed) -> some View {
        let speakingColor = Color(red: 0.03, green: 0.86, blue: 0.55)

        return ZStack(alignment: .bottomLeading) {
            VideoTrackView(track: feed.track, mirror: false)
                .id(feed.id)

            Text(feed.participantName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(feed.isSpeaking ? .black : .white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(feed.isSpeaking ? speakingColor : .black.opacity(0.45), in: Capsule())
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(feed.isSpeaking ? speakingColor : .white.opacity(0.12), lineWidth: feed.isSpeaking ? 3 : 1)
        )
        .shadow(color: feed.isSpeaking ? speakingColor.opacity(0.45) : .clear, radius: 12)
        .animation(.easeInOut(duration: 0.18), value: feed.isSpeaking)
    }

    private func tileFrames(count: Int, in proxy: GeometryProxy) -> [CGRect] {
        let columns = columnCount(for: count, size: proxy.size)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let available = CGRect(
            x: 0,
            y: 0,
            width: max(1, proxy.size.width),
            height: max(1, proxy.size.height)
        )
        let totalHorizontalGap = CGFloat(columns - 1) * tileGap
        let totalVerticalGap = CGFloat(rows - 1) * tileGap
        let tileWidth = (available.width - totalHorizontalGap) / CGFloat(columns)
        let tileHeight = (available.height - totalVerticalGap) / CGFloat(rows)

        return (0..<count).map { index in
            let row = index / columns
            let column = index % columns
            return CGRect(
                x: available.minX + CGFloat(column) * (tileWidth + tileGap),
                y: available.minY + CGFloat(row) * (tileHeight + tileGap),
                width: tileWidth,
                height: tileHeight
            )
        }
    }

    private func columnCount(for count: Int, size: CGSize) -> Int {
        if count <= 2 { return size.width > size.height ? count : 1 }
        if count <= 4 { return 2 }
        return size.width > 600 ? 3 : 2
    }
}

private struct AddVideoParticipantsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient

    let callID: String
    let currentPeerNumber: String

    @State private var contacts = [Contact]()
    @State private var searchText = ""
    @State private var selectedNumbers = Set<String>()
    @State private var loading = false
    @State private var adding = false
    @State private var addError: String?

    private var normalizedSearchNumber: String {
        searchText.filter { $0.isNumber || "*#+".contains($0) }
    }

    private var visibleContacts: [Contact] {
        let available = contacts.filter { $0.sipNumber != currentPeerNumber }
        guard !searchText.isEmpty else { return available }
        let number = normalizedSearchNumber
        return available.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            (!number.isEmpty && $0.sipNumber.contains(number)) ||
            $0.sipNumber.contains(searchText)
        }
    }

    private var numbersToInvite: [String] {
        var seen = Set<String>()
        let numbers = selectedNumbers.isEmpty
            ? Array(selectedNumbers) + [normalizedSearchNumber]
            : Array(selectedNumbers)
        return numbers.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var canAddParticipants: Bool {
        !adding && !numbersToInvite.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.secondary)
                    TextField("Поиск или номер абонента", text: $searchText)
                        .font(.body)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(uiColor: .tertiarySystemFill))
                .cornerRadius(14)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                if loading && contacts.isEmpty {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    List {
                        if !normalizedSearchNumber.isEmpty {
                            participantRow(
                                title: normalizedSearchNumber,
                                subtitle: "Номер",
                                isSelected: selectedNumbers.contains(normalizedSearchNumber)
                            ) {
                                toggle(normalizedSearchNumber)
                            }
                        }

                        Section("Доступные абоненты") {
                            ForEach(visibleContacts) { contact in
                                participantRow(
                                    title: contact.displayName,
                                    subtitle: contact.sipNumber,
                                    isSelected: selectedNumbers.contains(contact.sipNumber)
                                ) {
                                    toggle(contact.sipNumber)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await loadContacts() }
                }

                if let addError {
                    Text(addError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
            }
            .navigationTitle("Добавить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(adding ? "Добавление" : "Добавить") {
                        let numbers = numbersToInvite
                        adding = true
                        addError = nil
                        Task {
                            let error = await model.addVideoParticipants(callID: callID, peerNumbers: numbers)
                            adding = false
                            if let error {
                                addError = error
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .bold()
                    .disabled(!canAddParticipants)
                }
            }
            .task { if contacts.isEmpty { await loadContacts() } }
        }
    }

    private func participantRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .fill(Color.tvoiceBlue)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Text("T7")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.tvoiceNavy)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.tvoiceBlue : Color.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ sipNumber: String) {
        if selectedNumbers.contains(sipNumber) {
            selectedNumbers.remove(sipNumber)
        } else {
            selectedNumbers.insert(sipNumber)
        }
    }

    private func loadContacts() async {
        loading = true
        defer { loading = false }
        do {
            contacts = try await api.contacts()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct VideoTrackView: UIViewRepresentable {
    let track: VideoTrack
    let mirror: Bool

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fill
        view.mirrorMode = mirror ? .mirror : .off
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        view.layoutMode = .fill
        view.mirrorMode = mirror ? .mirror : .off
        view.track = track
    }

    static func dismantleUIView(_ view: VideoView, coordinator: ()) {
        view.track = nil
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
