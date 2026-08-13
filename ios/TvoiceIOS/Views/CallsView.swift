import SwiftUI

struct CallsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient
    @State private var showDialpad = false

    @State private var callHistory: [CallRecord] = []
    @State private var isLoading = false

    var body: some View {
        ZStack {
            NavigationView {
                VStack(spacing: 0) {
                    // Call History List
                    if isLoading && callHistory.isEmpty {
                        Spacer()
                        ProgressView("Загрузка историй звонков…")
                        Spacer()
                    } else if callHistory.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "phone.fill.badge.plus")
                                .font(.system(size: 56))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                            Text("История звонков пуста")
                                .font(.headline)
                                .foregroundStyle(Color.secondary)
                            Text("Нажмите синюю кнопку внизу, чтобы набрать номер")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            Spacer()
                        }
                    } else {
                        List {
                            Section {
                                ForEach(callHistory) { call in
                                    CallRecordRow(call: call) {
                                        Task {
                                            if call.isVideo {
                                                await model.startVideoCall(peer: call.peerNumber)
                                            } else {
                                                await model.startAudioCall(peer: call.peerNumber)
                                            }
                                        }
                                    }
                                }
                            } header: {
                                Text("Недавние звонки")
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
                .navigationTitle("Звонки")
                .task {
                    await loadCallHistory()
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(api.isConnected ? Color.tvoiceGreen : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(api.isConnected ? "В сети" : "Подключение…")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(api.isConnected ? Color.tvoiceGreen : Color.orange)
                        }
                    }
                }
            }

            // Floating Action Button (FAB) for Dialpad
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showDialpad = true
                    } label: {
                        Circle()
                            .fill(Color.tvoiceBlue)
                            .frame(width: 60, height: 60)
                            .overlay(
                                Image(systemName: "circle.grid.3x3.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                            )
                            .shadow(color: Color.tvoiceBlue.opacity(0.4), radius: 8, x: 0, y: 4)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $showDialpad) {
            DialpadSheetView()
                .environmentObject(model)
                .environmentObject(api)
        }
    }

    private func loadCallHistory() async {
        isLoading = true
        defer { isLoading = false }
        
        let localLogs = LocalCallHistoryStore.loadAll().map { log -> CallRecord in
            let dir: CallDirection
            switch log.direction {
            case "missed": dir = .missed
            case "outgoing": dir = .outgoing
            default: dir = .incoming
            }
            return CallRecord(
                id: log.id,
                peerNumber: log.sipNumber,
                peerName: log.displayName,
                direction: dir,
                timestamp: log.timestamp,
                isVideo: log.isVideo
            )
        }
        
        do {
            let apiLogs = try await api.callLogs()
            callHistory = apiLogs.isEmpty ? localLogs : apiLogs
        } catch {
            callHistory = localLogs
        }
    }
}

struct CallRecordRow: View {
    let call: CallRecord
    let onCall: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Peer T7 Avatar
            ZStack {
                Circle()
                    .fill(Color.tvoiceBlue)
                    .frame(width: 44, height: 44)
                Text("T7")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(call.peerName)
                    .font(.headline)
                    .foregroundStyle(call.direction == .missed ? Color.red : Color.primary)
                
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: call.direction))
                        .font(.caption2.bold())
                        .foregroundStyle(iconColor(for: call.direction))
                    
                    Text(directionText(for: call.direction))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    
                    Text(formattedDate(call.timestamp))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer()

            Button(action: onCall) {
                Image(systemName: call.isVideo ? "video.fill" : "phone.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.tvoiceBlue)
                    .padding(8)
                    .background(Circle().fill(Color.tvoiceBlue.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func iconName(for direction: CallDirection) -> String {
        switch direction {
        case .incoming: return "arrow.down.left"
        case .outgoing: return "arrow.up.right"
        case .missed: return "phone.down.fill"
        }
    }

    private func iconColor(for direction: CallDirection) -> Color {
        switch direction {
        case .incoming: return Color.tvoiceGreen
        case .outgoing: return Color.tvoiceBlue
        case .missed: return Color.red
        }
    }

    private func directionText(for direction: CallDirection) -> String {
        switch direction {
        case .incoming: return "Входящий"
        case .outgoing: return "Исходящий"
        case .missed: return "Пропущенный"
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct DialpadSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var api: ChatAPIClient
    @State private var number = ""

    private let keyMatrix: [[(digit: String, letters: String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Status header
            VStack(spacing: 4) {
                Text("Tvoice Dialpad")
                    .font(.title3.bold())
                    .foregroundStyle(Color.tvoiceBlue)
                
                if let user = model.user {
                    Text(user.sipNumber)
                        .font(.title2.bold())
                        .foregroundStyle(Color.tvoiceNavy)
                }
            }
            .padding(.bottom, 12)

            Spacer()

            // Number Input Display
            HStack {
                Spacer()
                Text(number.isEmpty ? "Введите номер" : number)
                    .font(.system(size: 32, weight: .medium, design: .rounded))
                    .foregroundStyle(number.isEmpty ? Color.secondary.opacity(0.6) : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()

                if !number.isEmpty {
                    Button {
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.title2)
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.trailing, 24)
                }
            }
            .frame(height: 56)
            .padding(.horizontal, 24)

            Spacer()

            // Native Styled Dialpad Grid
            VStack(spacing: 16) {
                ForEach(keyMatrix, id: \.[0].digit) { row in
                    HStack(spacing: 24) {
                        ForEach(row, id: \.digit) { item in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                number.append(item.digit)
                            } label: {
                                VStack(spacing: 2) {
                                    Text(item.digit)
                                        .font(.system(size: 32, weight: .regular))
                                        .foregroundStyle(Color.tvoiceNavy)
                                    if !item.letters.isEmpty {
                                        Text(item.letters)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Color.secondary.opacity(0.7))
                                    }
                                }
                                .frame(width: 72, height: 72)
                                .background(
                                    Circle()
                                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                        .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 3)
                                )
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 20)

            // Bottom Call Action Buttons
            HStack(spacing: 36) {
                // Video Call
                Button {
                    guard !number.isEmpty else { return }
                    let peer = number
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        Task { @MainActor in
                            await model.startVideoCall(peer: peer)
                        }
                    }
                } label: {
                    Circle()
                        .fill(Color.tvoiceBlue)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: "video.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        )
                        .shadow(color: Color.tvoiceBlue.opacity(0.35), radius: 8, x: 0, y: 4)
                }

                // Audio SIP Call
                Button {
                    guard !number.isEmpty else { return }
                    let peer = number
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        Task { @MainActor in
                            await model.startAudioCall(peer: peer)
                        }
                    }
                } label: {
                    Circle()
                        .fill(Color.tvoiceGreen)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: "phone.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        )
                        .shadow(color: Color.tvoiceGreen.opacity(0.35), radius: 8, x: 0, y: 4)
                }
            }
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}
