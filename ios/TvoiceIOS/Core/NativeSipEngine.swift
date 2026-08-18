import Foundation
import Network
import AVFoundation
import UIKit
import Darwin

@MainActor
final class NativeSipEngine: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var currentCallID: String?
    @Published private(set) var isCallHeld = false
    @Published private(set) var callState: SipCallState = .idle {
        didSet {
            objectWillChange.send()
        }
    }

    enum SipCallState: Equatable {
        case idle
        case incoming(peer: String)
        case calling(peer: String)
        case connected(peer: String)
        case failed(reason: String)
    }

    private var connection: NWConnection?
    private var ownNumber = ""
    private var ownPassword = ""
    private var ringbackPlayer: AVAudioPlayer?
    private var incomingRingtonePlayer: AVAudioPlayer?
    private var registerCallId = UUID().uuidString
    private var registerTag = String(UUID().uuidString.prefix(8))
    private var cseq = 1
    private var nonceCount = 1
    private var registrationChallenge: DigestChallenge?
    private var registrationAuthHeaderName = "Authorization"
    private var registrationAuthAttempts = 0
    private var registrationRequestedExpires = 0
    private var registrationPendingCSeq: Int?
    private var registrationRetryDelaySeconds: UInt64 = 5
    private var registrationRefreshTask: Task<Void, Never>?
    private var registrationRetryTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var incomingInviteMessage: String?
    private var currentCallPeer: String = ""
    private var activeDialog: SipDialog?
    private var rtpAudioEngine: RtpAudioEngine?
    private var pendingHold: Bool?

    func register(sipNumber: String, password: String) {
        self.ownNumber = sipNumber
        self.ownPassword = password
        self.mappedContact = nil
        self.mappedContactPort = nil
        self.registerCallId = UUID().uuidString
        self.registerTag = String(UUID().uuidString.prefix(8))
        self.cseq = 0
        self.nonceCount = 0
        self.registrationChallenge = nil
        self.registrationAuthHeaderName = "Authorization"
        self.registrationAuthAttempts = 0
        self.registrationRequestedExpires = 0
        self.registrationPendingCSeq = nil
        self.registrationRetryDelaySeconds = 5
        self.isRegistered = false
        stopRegistrationTimers()
        startPathMonitor()
        connection?.cancel()
        connection = nil
        connectUDP()
    }
    
    func unregister() {
        sendSipUnregister()
        stopRegistrationTimers()
        stopPathMonitor()
        connection?.cancel()
        connection = nil
        isRegistered = false
    }

    func setMuted(_ muted: Bool) {
        rtpAudioEngine?.setMuted(muted)
    }

    func handleSystemAudioSessionActivated() {
        rtpAudioEngine?.handleSystemAudioSessionActivated()
    }
    
    func startAudioCall(peer: String) async throws {
        guard isRegistered else {
            throw NSError(
                domain: "NativeSipEngine",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "SIP ещё не подключён. Подождите регистрацию и попробуйте снова."]
            )
        }
        guard activeDialog == nil else {
            throw NSError(
                domain: "NativeSipEngine",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Другой SIP-звонок уже активен"]
            )
        }
        let callIdHost = localSignalingEndpoint()?.host ?? localIPv4Address() ?? AppConfig.sipHost
        let dialog = SipDialog(
            direction: .outgoing,
            peerNumber: peer,
            callID: "\(SipDialog.randomHex(12))@\(callIdHost)",
            localTag: SipDialog.randomHex(8)
        )
        self.activeDialog = dialog
        self.currentCallPeer = peer
        self.currentCallID = dialog.callID
        self.callState = .calling(peer: peer)
        
        try await prepareAudioSessionForMicrophone()
        
        try sendSipInvite(to: peer, dialog: dialog)
    }

    func acceptCall() async {
        guard case let .incoming(peer) = callState, let invite = incomingInviteMessage else { return }
        stopIncomingRingtone()
        do {
            try await prepareAudioSessionForMicrophone()
        } catch {
            sendIncomingInviteNotAcceptable(request: invite)
            callState = .failed(reason: error.localizedDescription)
            return
        }

        let dialog = activeDialog ?? SipDialog(direction: .incoming, peerNumber: peer)
        self.activeDialog = dialog
        self.currentCallPeer = peer
        
        guard let inviteMessage = SipMessage.parse(invite),
              let offer = SdpOfferAnswer.parse(inviteMessage.body, fallbackHost: AppConfig.sipHost),
              let localAddress = localSdpAddress() else {
            sendIncomingInviteNotAcceptable(request: invite)
            callState = .failed(reason: "FreePBX не передал корректный RTP-адрес")
            return
        }

        let rtpEngine = RtpAudioEngine()
        self.rtpAudioEngine = rtpEngine
        do {
            let boundPort = try rtpEngine.prepare()
            printMediaRoute(localHost: localAddress.host, localPort: boundPort, offer: offer)
            sendIncomingInviteOk(
                request: invite,
                localAddress: localAddress,
                localRtpPort: boundPort,
                payloadType: offer.selectedCodecPayload
            )
            dialog.accepted = true
            self.callState = .connected(peer: peer)
        } catch {
            rtpEngine.stop()
            self.rtpAudioEngine = nil
            sendIncomingInviteNotAcceptable(request: invite)
            self.callState = .failed(reason: error.localizedDescription)
        }
    }

    func rejectCall() {
        if let invite = incomingInviteMessage {
            sendIncomingInviteReject(request: invite)
        }
        resetCurrentCall()
    }
    
    func toggleSpeaker(enabled: Bool) {
        rtpAudioEngine?.setSpeaker(enabled)
    }

    func endCall() {
        if case .incoming = callState {
            rejectCall()
            return
        }
        if let dialog = activeDialog {
            if case .calling = callState {
                sendSipCancel(dialog: dialog)
            } else if case .connected = callState {
                sendSipBye(dialog: dialog)
            }
        }
        resetCurrentCall()
    }

    func toggleHold() {
        guard case .connected = callState, let dialog = activeDialog, pendingHold == nil else { return }
        let target = !isCallHeld
        pendingHold = target
        dialog.localCSeq += 1
        dialog.viaBranch = SipDialog.newBranch()
        sendReinvite(dialog: dialog, hold: target)
    }

    func moveCurrentCallToConference(room: String) async throws {
        let normalized = room.filter { $0.isNumber || "*#+".contains($0) }
        guard !normalized.isEmpty else { return }
        guard case .connected = callState, let dialog = activeDialog else {
            throw RtpAudioEngine.MediaError.invalidRemoteEndpoint("conference", 0)
        }
        sendSipRefer(dialog: dialog, target: normalized)
        endCall()
        try await Task.sleep(nanoseconds: 350_000_000)
        try await startAudioCall(peer: normalized)
    }

    private func resetCurrentCall() {
        stopRingbackTone()
        stopIncomingRingtone()
        rtpAudioEngine?.stop()
        rtpAudioEngine = nil
        activeDialog = nil
        currentCallID = nil
        incomingInviteMessage = nil
        currentCallPeer = ""
        pendingHold = nil
        isCallHeld = false
        callState = .idle
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func prepareAudioSessionForMicrophone() async throws {
        let audioSession = AVAudioSession.sharedInstance()
        let granted: Bool
        switch audioSession.recordPermission {
        case .granted:
            granted = true
        case .denied:
            granted = false
        case .undetermined:
            granted = await withCheckedContinuation { continuation in
                audioSession.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        @unknown default:
            granted = false
        }
        guard granted else {
            throw NSError(
                domain: "NativeSipEngine",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "Нет доступа к микрофону. Разрешите микрофон в настройках iOS."]
            )
        }

        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try audioSession.setPreferredSampleRate(48_000)
        try audioSession.setPreferredIOBufferDuration(0.02)
        try audioSession.overrideOutputAudioPort(.none)
        try audioSession.setActive(true)
    }
    
    private func playRingbackTone() {
        stopRingbackTone()
        do {
            ringbackPlayer = try AVAudioPlayer(data: toneWavData(frequencies: [425], toneDuration: 1.5, totalDuration: 4.0, amplitude: 0.5))
            ringbackPlayer?.numberOfLoops = -1
            ringbackPlayer?.prepareToPlay()
            ringbackPlayer?.play()
        } catch {
            print("Failed to play ringback tone:", error)
        }
    }

    private func stopRingbackTone() {
        ringbackPlayer?.stop()
        ringbackPlayer = nil
    }

    private func playIncomingRingtone() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard incomingRingtonePlayer?.isPlaying != true else { return }
        stopIncomingRingtone()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            if let systemRingtoneURL = systemRingtoneURL() {
                print("Incoming ringtone source: system \(systemRingtoneURL.path)")
                incomingRingtonePlayer = try AVAudioPlayer(contentsOf: systemRingtoneURL)
            } else {
                print("Incoming ringtone source: generated fallback")
                incomingRingtonePlayer = try AVAudioPlayer(
                    data: toneWavData(frequencies: [440, 480], toneDuration: 2.0, totalDuration: 4.0, amplitude: 0.8)
                )
            }
            incomingRingtonePlayer?.numberOfLoops = -1
            incomingRingtonePlayer?.volume = 1.0
            incomingRingtonePlayer?.prepareToPlay()
            incomingRingtonePlayer?.play()
        } catch {
            print("Failed to play incoming ringtone:", error)
        }
    }

    private func stopIncomingRingtone() {
        incomingRingtonePlayer?.stop()
        incomingRingtonePlayer = nil
    }

    private func systemRingtoneURL() -> URL? {
        [
            "/Library/Ringtones/Opening.m4r",
            "/Library/Ringtones/Reflection.m4r",
            "/System/Library/Audio/UISounds/Ringtones/Opening.m4r",
            "/System/Library/Audio/UISounds/Ringtones/Reflection.m4r",
            "/System/Library/Audio/UISounds/nano/Ringtone_UK_Haptic.caf",
            "/System/Library/Audio/UISounds/nano/Ringtone_US_Haptic.caf"
        ]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func toneWavData(
        frequencies: [Double],
        toneDuration: Double,
        totalDuration: Double,
        amplitude: Double
    ) -> Data {
        let sampleRate = 44100.0
        let totalSamples = Int(sampleRate * totalDuration)
        let toneSamples = Int(sampleRate * toneDuration)
        let clampedAmplitude = max(0.0, min(1.0, amplitude))

        var samples = [Int16]()
        samples.reserveCapacity(totalSamples)

        for i in 0..<totalSamples {
            if i < toneSamples {
                let t = Double(i) / sampleRate
                let mixed = frequencies.reduce(0.0) { partial, frequency in
                    partial + sin(2.0 * Double.pi * frequency * t)
                } / Double(max(frequencies.count, 1))
                samples.append(Int16(mixed * Double(Int16.max) * clampedAmplitude))
            } else {
                samples.append(0)
            }
        }

        let data = Data(bytes: samples, count: totalSamples * 2)
        var wavHeader = Data()
        wavHeader.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(36 + data.count).littleEndian
        wavHeader.append(Data(bytes: &fileSize, count: 4))
        wavHeader.append(contentsOf: "WAVEfmt ".utf8)
        var fmtChunkSize = UInt32(16).littleEndian
        wavHeader.append(Data(bytes: &fmtChunkSize, count: 4))
        var formatType = UInt16(1).littleEndian
        wavHeader.append(Data(bytes: &formatType, count: 2))
        var channels = UInt16(1).littleEndian
        wavHeader.append(Data(bytes: &channels, count: 2))
        var sRate = UInt32(sampleRate).littleEndian
        wavHeader.append(Data(bytes: &sRate, count: 4))
        var byteRate = UInt32(sampleRate * 2).littleEndian
        wavHeader.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(2).littleEndian
        wavHeader.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample = UInt16(16).littleEndian
        wavHeader.append(Data(bytes: &bitsPerSample, count: 2))
        wavHeader.append(contentsOf: "data".utf8)
        var dataSize = UInt32(data.count).littleEndian
        wavHeader.append(Data(bytes: &dataSize, count: 4))

        var fullWav = Data()
        fullWav.append(wavHeader)
        fullWav.append(data)
        return fullWav
    }

    private func stopRegistrationTimers() {
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        registrationPendingCSeq = nil
    }

    private func startRegistrationRefresh() {
        registrationRefreshTask?.cancel()
        registrationRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.isRegistered, !self.ownNumber.isEmpty else { return }
                    self.sendSipRegister(expires: 300)
                }
            }
        }
    }

    private func scheduleRegistrationTimeout(for pendingCSeq: Int) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            await MainActor.run {
                guard
                    let self,
                    self.registrationPendingCSeq == pendingCSeq,
                    self.registrationRequestedExpires > 0
                else { return }
                self.failRegistration("SIP-сервер не ответил", retry: true)
            }
        }
    }

    private func failRegistration(_ message: String, retry: Bool) {
        isRegistered = false
        registrationPendingCSeq = nil
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
        print("SIP registration failed:", message)
        guard retry, !ownNumber.isEmpty, !ownPassword.isEmpty else { return }
        registrationRetryTask?.cancel()
        let delay = registrationRetryDelaySeconds
        registrationRetryDelaySeconds = min(registrationRetryDelaySeconds * 2, 60)
        registrationRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            await MainActor.run {
                guard let self, !self.isRegistered, !self.ownNumber.isEmpty else { return }
                self.registerCallId = UUID().uuidString
                self.registerTag = String(UUID().uuidString.prefix(8))
                self.cseq = 0
                self.nonceCount = 0
                self.registrationChallenge = nil
                self.registrationAuthHeaderName = "Authorization"
                self.registrationAuthAttempts = 0
                self.reconnectUDPForRegistration()
            }
        }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.pathSignature(path)
            Task { @MainActor in
                guard let self else { return }
                if self.lastPathSignature == nil {
                    self.lastPathSignature = signature
                    return
                }
                guard self.lastPathSignature != signature else { return }
                self.lastPathSignature = signature
                guard path.status == .satisfied else {
                    self.failRegistration("Сеть недоступна", retry: true)
                    return
                }
                self.reconnectUDPForRegistration()
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
    }

    nonisolated private static func pathSignature(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.type)" }
            .sorted()
            .joined(separator: ",")
        return "\(path.status)-\(interfaces)"
    }

    private func reconnectUDPForRegistration() {
        guard !ownNumber.isEmpty, !ownPassword.isEmpty else { return }
        if activeDialog != nil {
            resetCurrentCall()
        }
        mappedContact = nil
        mappedContactPort = nil
        isRegistered = false
        registrationPendingCSeq = nil
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
        connection?.cancel()
        connection = nil
        connectUDP()
    }
    
    private func connectUDP() {
        let host = NWEndpoint.Host(AppConfig.sipHost)
        let port = NWEndpoint.Port(rawValue: AppConfig.sipPort)!
        
        let connection = NWConnection(host: host, port: port, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.sendSipRegister()
                case .failed(let err):
                    self?.isRegistered = false
                    print("SIP UDP Connection failed:", err)
                default:
                    break
                }
            }
        }
        connection.start(queue: .global())
        self.connection = connection
        listenUDP()
    }

    private func listenUDP() {
        connection?.receiveMessage { [weak self] content, _, _, error in
            if let data = content, let message = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self?.handleSipMessage(message)
                }
            }
            if error == nil {
                Task { @MainActor in
                    self?.listenUDP()
                }
            }
        }
    }

    private var mappedContact: String?
    private var mappedContactPort: UInt16?

    private func handleSipMessage(_ message: String) {
        print("Received SIP UDP packet:", message)

        guard let parsed = SipMessage.parse(message) else {
            print("Ignoring malformed SIP packet")
            return
        }
        let cseqMethod = parsed.cseqMethod
        let cseqNumber = parsed.cseqNumber
        let mappingChanged = updateMappedContact(from: parsed.header("Via"))

        if let status = parsed.statusCode {
            switch cseqMethod {
            case "REGISTER":
                if let cseqNumber, let pending = registrationPendingCSeq, cseqNumber != pending { return }
                handleRegisterResponse(message: message, parsed: parsed, status: status, mappingChanged: mappingChanged)
            case "INVITE":
                handleInviteResponse(message: message, parsed: parsed, status: status)
            default:
                break
            }
            return
        }

        switch parsed.method {
        case "INVITE":
            handleIncomingInvite(rawMessage: message, parsed: parsed)
        case "ACK":
            handleIncomingAck(parsed: parsed)
        case "BYE":
            sendRequestOk(request: message)
            resetCurrentCall()
        case "CANCEL":
            sendRequestOk(request: message)
            if let invite = incomingInviteMessage {
                sendResponse(status: "487 Request Terminated", request: invite, addLocalToTag: true)
            }
            resetCurrentCall()
        case "OPTIONS", "INFO", "NOTIFY", "UPDATE":
            sendResponse(status: "200 OK", request: message, addLocalToTag: true)
        default:
            sendResponse(status: "501 Not Implemented", request: message, addLocalToTag: true)
        }
    }

    private func handleRegisterResponse(message: String, parsed: SipMessage, status: Int, mappingChanged: Bool) {
        switch status {
        case 200:
            registrationPendingCSeq = nil
            registrationAuthAttempts = 0
            if registrationRequestedExpires == 0 {
                isRegistered = false
                registrationRefreshTask?.cancel()
                registrationRefreshTask = nil
                return
            }
            isRegistered = true
            registrationRetryTask?.cancel()
            registrationRetryTask = nil
            registrationRetryDelaySeconds = 5
            startRegistrationRefresh()
            print("Successfully registered on FreePBX as Available:", ownNumber)
            if mappingChanged {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await MainActor.run {
                        guard let self, self.isRegistered else { return }
                        self.sendSipRegister(expires: 300)
                    }
                }
            }
        case 401, 407:
            if registrationAuthAttempts >= 2 {
                failRegistration("Сервер отклонил логин или пароль", retry: false)
                return
            }
            let challengeHeader = status == 407 ? "Proxy-Authenticate" : "WWW-Authenticate"
            guard let authLine = parsed.header(challengeHeader),
                  let challenge = DigestChallenge.parse("\(challengeHeader): \(authLine)") else {
                failRegistration("Сервер не прислал параметры авторизации", retry: false)
                return
            }
            registrationChallenge = challenge
            registrationAuthHeaderName = status == 407 ? "Proxy-Authorization" : "Authorization"
            registrationAuthAttempts += 1
            sendSipRegister(expires: 300)
        case 300...699:
            failRegistration("SIP \(status) \(parsed.startLine)", retry: status == 408 || status >= 500)
        default:
            break
        }
    }

    private func handleInviteResponse(message: String, parsed: SipMessage, status: Int) {
        guard let dialog = activeDialog, parsed.header("Call-ID") == dialog.callID else {
            print("Ignoring SIP INVITE response for another dialog:", parsed.header("Call-ID") ?? "missing Call-ID")
            return
        }
        if (101...299).contains(status) {
            dialog.updateEarlyDialog(fromInviteResponse: parsed)
        }
        switch status {
        case 100, 183:
            break
        case 180:
            if case .calling = callState, activeDialog?.connected != true {
                playRingbackTone()
            }
        case 401, 407:
            guard case let .calling(peer) = callState,
                  let dialog = activeDialog else { return }
            sendInviteChallengeAck(response: message, dialog: dialog)
            dialog.remoteTag = nil
            dialog.routeSet = []
            dialog.localCSeq += 1
            dialog.viaBranch = SipDialog.newBranch()
            let challengeHeader = status == 407 ? "Proxy-Authenticate" : "WWW-Authenticate"
            guard let authLine = parsed.header(challengeHeader),
                  let challenge = DigestChallenge.parse("\(challengeHeader): \(authLine)") else {
                callState = .failed(reason: "Ошибка авторизации вызова")
                return
            }
            let authHeaderName = status == 407 ? "Proxy-Authorization" : "Authorization"
            let authHeader = DigestAuth.create(
                challenge: challenge,
                username: ownNumber,
                password: ownPassword,
                method: "INVITE",
                uri: "sip:\(peer)@\(AppConfig.sipHost)",
                nonceCount: 1
            )
            sendAuthenticatedInvite(
                to: peer,
                authHeaderName: authHeaderName,
                authHeader: authHeader,
                dialog: dialog
            )
        case 200...299:
            guard let offer = SdpOfferAnswer.parse(parsed.body, fallbackHost: AppConfig.sipHost) else {
                stopRingbackTone()
                rtpAudioEngine?.stop()
                rtpAudioEngine = nil
                callState = .failed(reason: "В ответе FreePBX отсутствует корректный SDP/RTP")
                return
            }
            dialog.update(fromInviteResponse: parsed)
            sendSipAck(response: parsed, dialog: dialog)
            stopRingbackTone()

            let peerToConnect = currentCallPeer.isEmpty ? "Собеседник" : currentCallPeer
            do {
                let rtpEngine: RtpAudioEngine
                if let existing = rtpAudioEngine {
                    rtpEngine = existing
                } else {
                    let created = RtpAudioEngine()
                    try created.prepare()
                    self.rtpAudioEngine = created
                    rtpEngine = created
                }
                try rtpEngine.activate(
                    remoteHost: offer.mediaHost,
                    remotePort: offer.mediaPort,
                    payloadType: offer.selectedCodecPayload
                )
                let localHost = localSdpAddress()?.host ?? "unknown"
                printMediaRoute(localHost: localHost, localPort: rtpEngine.localPort, offer: offer)
                if let hold = pendingHold {
                    isCallHeld = hold
                    rtpEngine.setHeld(hold)
                    pendingHold = nil
                }
                activeDialog?.connected = true
                self.callState = .connected(peer: peerToConnect)
            } catch {
                rtpAudioEngine?.stop()
                rtpAudioEngine = nil
                self.callState = .failed(reason: error.localizedDescription)
            }
        case 486, 487, 603:
            let failedPeer: String?
            if case let .calling(peer) = callState {
                failedPeer = peer
            } else {
                failedPeer = nil
            }
            if let dialog = activeDialog {
                sendInviteChallengeAck(response: message, dialog: dialog)
            }
            stopRingbackTone()
            resetCurrentCall()
            if let failedPeer {
                LocalCallHistoryStore.saveCall(sipNumber: failedPeer, displayName: failedPeer, direction: "missed", isVideo: false)
            }
            self.callState = .failed(reason: "Занято или вызов отклонен")
        case 300...699:
            if let dialog = activeDialog {
                sendInviteChallengeAck(response: message, dialog: dialog)
            }
            stopRingbackTone()
            resetCurrentCall()
            self.callState = .failed(reason: inviteFailureReason(status: status, parsed: parsed))
        default:
            break
        }
    }

    private func inviteFailureReason(status: Int, parsed: SipMessage) -> String {
        let detail = parsed.header("Reason")
            ?? parsed.header("Warning")
            ?? parsed.startLine
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        switch status {
        case 404:
            return "SIP 404: номер не найден\(suffix)"
        case 480:
            return "SIP 480: абонент временно недоступен\(suffix)"
        case 486:
            return "SIP 486: абонент занят\(suffix)"
        case 503:
            return "SIP 503: FreePBX не нашёл доступный endpoint или маршрут\(suffix)"
        default:
            return "SIP \(status)\(suffix)"
        }
    }

    private func handleIncomingInvite(rawMessage message: String, parsed: SipMessage) {
        guard isRegistered else {
            sendResponse(status: "480 Temporarily Unavailable", request: message, addLocalToTag: true)
            return
        }
        guard let incoming = SipDialog.incoming(peerNumber: "", request: parsed) else {
            sendIncomingInviteNotAcceptable(request: message)
            return
        }
        if let activeDialog, activeDialog.callID == incoming.callID {
            incomingInviteMessage = message
            if activeDialog.accepted {
                resendIncomingInviteOk(request: message)
            } else {
                playIncomingRingtone()
                sendIncomingInviteRinging(request: message)
            }
            return
        }
        if activeDialog != nil || rtpAudioEngine != nil {
            sendIncomingInviteReject(request: message)
            return
        }
        guard SdpOfferAnswer.parse(parsed.body, fallbackHost: AppConfig.sipHost) != nil else {
            sendIncomingInviteNotAcceptable(request: message)
            return
        }
        let fromUri = SipDialog.uri(in: parsed.header("From")) ?? ""
        let callerNumber = fromUri
            .replacingOccurrences(of: "sip:", with: "")
            .split(separator: "@")
            .first
            .map(String.init) ?? "Неизвестный"
        incomingInviteMessage = message
        currentCallPeer = callerNumber
        activeDialog = SipDialog.incoming(peerNumber: callerNumber, request: parsed)
        currentCallID = incoming.callID
        callState = .incoming(peer: callerNumber)
        playIncomingRingtone()

        sendResponse(status: "100 Trying", request: message, addLocalToTag: false)
        sendIncomingInviteRinging(request: message)
    }

    private func handleIncomingAck(parsed: SipMessage) {
        guard let dialog = activeDialog,
              dialog.direction == .incoming,
              dialog.accepted,
              !dialog.connected,
              parsed.header("Call-ID") == dialog.callID,
              let invite = incomingInviteMessage,
              let inviteMessage = SipMessage.parse(invite),
              let offer = SdpOfferAnswer.parse(inviteMessage.body, fallbackHost: AppConfig.sipHost),
              let rtpEngine = rtpAudioEngine else { return }
        do {
            try rtpEngine.activate(
                remoteHost: offer.mediaHost,
                remotePort: offer.mediaPort,
                payloadType: offer.selectedCodecPayload
            )
            stopIncomingRingtone()
            let localHost = localSdpAddress()?.host ?? "unknown"
            printMediaRoute(localHost: localHost, localPort: rtpEngine.localPort, offer: offer)
            dialog.connected = true
            callState = .connected(peer: currentCallPeer.isEmpty ? dialog.peerNumber : currentCallPeer)
        } catch {
            rtpAudioEngine?.stop()
            rtpAudioEngine = nil
            callState = .failed(reason: error.localizedDescription)
        }
    }

    private static func cseqMethod(in lines: [String]) -> String? {
        guard let cseq = lines.first(where: { $0.lowercased().starts(with: "cseq:") }) else {
            return nil
        }
        return cseq
            .split(separator: " ")
            .last
            .map { String($0).uppercased() }
    }

    private static func headerLines(in raw: String) -> [String] {
        let head = raw.components(separatedBy: "\r\n\r\n").first ?? raw.components(separatedBy: "\n\n").first ?? raw
        return head.components(separatedBy: CharacterSet.newlines)
    }

    private func updateMappedContact(from via: String?) -> Bool {
        guard let via else { return false }
        var changed = false
        let nsLine = via as NSString
        if let pattern = try? NSRegularExpression(pattern: "(?:^|;)\\s*received=([^;,\\s]+)", options: .caseInsensitive),
           let match = pattern.firstMatch(in: via, range: NSRange(location: 0, length: nsLine.length)) {
            let receivedIp = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if !receivedIp.isEmpty, mappedContact != receivedIp {
                mappedContact = receivedIp
                changed = true
            }
        }
        if let rportPattern = try? NSRegularExpression(pattern: "(?:^|;)\\s*rport\\s*=\\s*(\\d+)", options: .caseInsensitive),
           let match = rportPattern.firstMatch(in: via, range: NSRange(location: 0, length: nsLine.length)),
           let port = UInt16(nsLine.substring(with: match.range(at: 1))),
           mappedContactPort != port {
            mappedContactPort = port
            changed = true
        }
        return changed
    }
    
    private func contactUri() -> String {
        let local = localSignalingEndpoint()
        let contactHost = mappedContact ?? local?.host ?? localIPv4Address() ?? "0.0.0.0"
        let contactPort = mappedContactPort ?? local?.port ?? AppConfig.sipPort
        return "sip:\(ownNumber)@\(formatSipHost(contactHost)):\(contactPort);transport=udp"
    }

    private func localSignalingEndpoint() -> (host: String, port: UInt16)? {
        guard let endpoint = connection?.currentPath?.localEndpoint,
              case let .hostPort(host, port) = endpoint else { return nil }
        return (normalizedHost(host), port.rawValue)
    }

    private func localSdpAddress() -> (network: String, host: String)? {
        let candidate = localSignalingEndpoint()?.host ?? localIPv4Address() ?? mappedContact
        guard let candidate,
              candidate != "0.0.0.0",
              candidate != AppConfig.sipHost else { return nil }
        return (candidate.contains(":") ? "IP6" : "IP4", candidate)
    }

    private func viaHeader(branch: String) -> String {
        let local = localSignalingEndpoint()
        let host = local?.host ?? localIPv4Address() ?? "0.0.0.0"
        let port = local?.port ?? AppConfig.sipPort
        return "Via: SIP/2.0/UDP \(formatSipHost(host)):\(port);rport;branch=\(branch)"
    }

    private func normalizedHost(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            return "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return host.debugDescription.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
    }

    private func formatSipHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    private func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let host = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockaddr -> String in
                let addr = sockaddr.pointee.sin_addr
                return String(cString: inet_ntoa(addr))
            }
            guard
                host != "0.0.0.0",
                !host.hasPrefix("127."),
                !host.hasPrefix("169.254.")
            else { continue }
            return host
        }
        return nil
    }

    private func printMediaRoute(
        localHost: String,
        localPort: UInt16,
        offer: SdpOfferAnswer
    ) {
        let codec = offer.selectedCodecPayload == 8 ? "PCMA/8000" : "PCMU/8000"
        print("SIP remote: \(AppConfig.sipHost):\(AppConfig.sipPort)/UDP")
        print("RTP local: \(localHost):\(localPort)/UDP")
        print("RTP remote: \(offer.mediaHost):\(offer.mediaPort)/UDP codec=\(codec)")
    }

    private func sendSipRegister(expires: Int = 300) {
        cseq += 1
        registrationRequestedExpires = expires
        registrationPendingCSeq = cseq
        var authLine = ""
        if let challenge = registrationChallenge {
            nonceCount += 1
            let authHeader = DigestAuth.create(
                challenge: challenge,
                username: ownNumber,
                password: ownPassword,
                method: "REGISTER",
                uri: "sip:\(AppConfig.sipHost):\(AppConfig.sipPort)",
                nonceCount: nonceCount
            )
            authLine = "\(registrationAuthHeaderName): \(authHeader)\r\n"
        }
        let sipMessage = """
        REGISTER sip:\(AppConfig.sipHost):5060 SIP/2.0\r
        \(viaHeader(branch: "z9hG4bK\(UUID().uuidString)"))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(registerTag)\r
        To: <sip:\(ownNumber)@\(AppConfig.sipHost)>\r
        Call-ID: \(registerCallId)\r
        CSeq: \(cseq) REGISTER\r
        Contact: <\(contactUri())>;ob;expires=\(expires)\r
        \(authLine)\
        Expires: \(expires)\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Supported: path, gruu, outbound\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipMessage.utf8))
        if expires > 0 {
            scheduleRegistrationTimeout(for: cseq)
        }
    }

    private func sendSipUnregister() {
        sendSipRegister(expires: 0)
    }

    private func sendAuthenticatedRegister(authHeaderName: String, authHeader: String) {
        let sipMessage = """
        REGISTER sip:\(AppConfig.sipHost):5060 SIP/2.0\r
        \(viaHeader(branch: "z9hG4bK\(UUID().uuidString)"))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(registerTag)\r
        To: <sip:\(ownNumber)@\(AppConfig.sipHost)>\r
        Call-ID: \(registerCallId)\r
        CSeq: \(cseq) REGISTER\r
        Contact: <\(contactUri())>;ob;expires=3600\r
        \(authHeaderName): \(authHeader)\r
        Expires: 3600\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Supported: path, gruu, outbound\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipMessage.utf8))
    }
    
    private func sendSipInvite(to peer: String, dialog: SipDialog) throws {
        guard let localAddress = localSdpAddress() else {
            throw RtpAudioEngine.MediaError.invalidRemoteEndpoint("local", 0)
        }
        let rtpEngine = RtpAudioEngine()
        self.rtpAudioEngine = rtpEngine
        let boundPort = try rtpEngine.prepare()
        
        let sdpBody = audioSdp(localAddress: localAddress, localRtpPort: boundPort, payloadType: nil, hold: false)
        let bodyData = Data(sdpBody.utf8)
        let sipInvite = """
        INVITE sip:\(peer)@\(AppConfig.sipHost) SIP/2.0\r
        \(viaHeader(branch: dialog.viaBranch))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: <sip:\(peer)@\(AppConfig.sipHost)>\r
        Call-ID: \(dialog.callID)\r
        CSeq: \(dialog.localCSeq) INVITE\r
        Contact: <\(contactUri())>\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Supported: replaces, timer\r
        Content-Type: application/sdp\r
        Content-Length: \(bodyData.count)\r
        \r
        \(sdpBody)
        """
        send(data: Data(sipInvite.utf8))
    }

    private func audioSdp(
        localAddress: (network: String, host: String),
        localRtpPort: UInt16,
        payloadType: UInt8?,
        hold: Bool
    ) -> String {
        let payloads = payloadType.map { "\($0) 101" } ?? "8 0 101"
        let codecLines: String
        if let payloadType {
            codecLines = "a=rtpmap:\(payloadType) \(payloadType == 0 ? "PCMU/8000" : "PCMA/8000")\r\n"
        } else {
            codecLines = "a=rtpmap:8 PCMA/8000\r\na=rtpmap:0 PCMU/8000\r\n"
        }
        return """
        v=0\r
        o=Tvoice \(Int(Date().timeIntervalSince1970)) 1 IN \(localAddress.network) \(localAddress.host)\r
        s=Tvoice\r
        c=IN \(localAddress.network) \(localAddress.host)\r
        t=0 0\r
        m=audio \(localRtpPort) RTP/AVP \(payloads)\r
        \(codecLines)\
        a=rtpmap:101 telephone-event/8000\r
        a=fmtp:101 0-16\r
        a=ptime:20\r
        \(hold ? "a=sendonly" : "a=sendrecv")\r

        """
    }

    private func sendAuthenticatedInvite(
        to peer: String,
        authHeaderName: String,
        authHeader: String,
        dialog: SipDialog
    ) {
        guard let localAddress = localSdpAddress(),
              let boundPort = rtpAudioEngine?.localPort,
              boundPort > 0 else {
            callState = .failed(reason: "Не удалось подготовить локальный RTP-порт")
            return
        }
        let sdpBody = audioSdp(localAddress: localAddress, localRtpPort: boundPort, payloadType: nil, hold: false)
        let bodyData = Data(sdpBody.utf8)
        let sipInvite = """
        INVITE sip:\(peer)@\(AppConfig.sipHost) SIP/2.0\r
        \(viaHeader(branch: dialog.viaBranch))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: <sip:\(peer)@\(AppConfig.sipHost)>\r
        Call-ID: \(dialog.callID)\r
        CSeq: \(dialog.localCSeq) INVITE\r
        Contact: <\(contactUri())>\r
        \(authHeaderName): \(authHeader)\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Supported: replaces, timer\r
        Content-Type: application/sdp\r
        Content-Length: \(bodyData.count)\r
        \r
        \(sdpBody)
        """
        send(data: Data(sipInvite.utf8))
    }

    private func sendReinvite(dialog: SipDialog, hold: Bool) {
        guard let localAddress = localSdpAddress(),
              let localRtpPort = rtpAudioEngine?.localPort,
              localRtpPort > 0 else {
            pendingHold = nil
            return
        }
        let sdpBody = audioSdp(localAddress: localAddress, localRtpPort: localRtpPort, payloadType: nil, hold: hold)
        let bodyData = Data(sdpBody.utf8)
        let remoteTagPart = dialog.remoteTag != nil ? ";tag=\(dialog.remoteTag!)" : ""
        let reinvite = """
        INVITE \(dialog.remoteTarget) SIP/2.0\r
        \(viaHeader(branch: dialog.viaBranch))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: <sip:\(dialog.peerNumber)@\(AppConfig.sipHost)>\(remoteTagPart)\r
        Call-ID: \(dialog.callID)\r
        CSeq: \(dialog.localCSeq) INVITE\r
        Contact: <\(contactUri())>\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Supported: replaces, timer\r
        Content-Type: application/sdp\r
        Content-Length: \(bodyData.count)\r
        \r
        \(sdpBody)
        """
        send(data: Data(reinvite.utf8))
    }

    private func sendSipRefer(dialog: SipDialog, target: String) {
        dialog.localCSeq += 1
        dialog.viaBranch = SipDialog.newBranch()
        let remoteTagPart = dialog.remoteTag != nil ? ";tag=\(dialog.remoteTag!)" : ""
        let refer = """
        REFER \(dialog.remoteTarget) SIP/2.0\r
        \(viaHeader(branch: dialog.viaBranch))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: <sip:\(dialog.peerNumber)@\(AppConfig.sipHost)>\(remoteTagPart)\r
        Call-ID: \(dialog.callID)\r
        CSeq: \(dialog.localCSeq) REFER\r
        Contact: <\(contactUri())>\r
        Refer-To: <sip:\(target)@\(AppConfig.sipHost)>\r
        Referred-By: <sip:\(ownNumber)@\(AppConfig.sipHost)>\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(refer.utf8))
    }

    private func sendSipAck(response: SipMessage, dialog: SipDialog) {
        guard let to = response.header("To") else { return }
        let cseq = response.cseqNumber ?? dialog.localCSeq
        let routeLines = dialog.routeSet
            .map { "Route: \($0)\r\n" }
            .joined()
        let sipAck = """
        ACK \(dialog.remoteTarget) SIP/2.0\r
        \(viaHeader(branch: SipDialog.newBranch()))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: \(to)\r
        Call-ID: \(dialog.callID)\r
        CSeq: \(cseq) ACK\r
        \(routeLines)\
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipAck.utf8))
    }
    
    private func sendSipBye(dialog: SipDialog) {
        dialog.localCSeq += 1
        dialog.viaBranch = SipDialog.newBranch()
        let remoteTagPart = dialog.remoteTag != nil ? ";tag=\(dialog.remoteTag!)" : ""
        let sipBye = """
        BYE \(dialog.remoteTarget) SIP/2.0\r
        \(viaHeader(branch: dialog.viaBranch))\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: <sip:\(dialog.peerNumber)@\(AppConfig.sipHost)>\(remoteTagPart)\r
        Call-ID: \(dialog.callID)\r
        CSeq: \(dialog.localCSeq) BYE\r
        Max-Forwards: 70\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipBye.utf8))
    }

    private func sendSipCancel(dialog: SipDialog) {
        let cancel = """
        CANCEL \(dialog.requestURI) SIP/2.0\r
        \(viaHeader(branch: dialog.viaBranch))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: <sip:\(dialog.peerNumber)@\(AppConfig.sipHost)>\r
        Call-ID: \(dialog.callID)\r
        CSeq: \(dialog.localCSeq) CANCEL\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(cancel.utf8))
    }

    private func sendIncomingInviteRinging(request: String) {
        let lines = request.components(separatedBy: "\r\n")
        var viaHeader = ""
        var fromHeader = ""
        var toHeader = ""
        var callIdHeader = ""
        var cseqHeader = ""
        for line in lines {
            if line.lowercased().starts(with: "via:") { viaHeader = line }
            if line.lowercased().starts(with: "from:") { fromHeader = line }
            if line.lowercased().starts(with: "to:") { toHeader = line }
            if line.lowercased().starts(with: "call-id:") { callIdHeader = line }
            if line.lowercased().starts(with: "cseq:") { cseqHeader = line }
        }
        let toTag = activeDialog?.localTag ?? String(UUID().uuidString.prefix(8))
        let sipResponse = """
        SIP/2.0 180 Ringing\r
        \(viaHeader)\r
        \(fromHeader)\r
        \(toHeader.contains("tag=") ? toHeader : "\(toHeader);tag=\(toTag)")\r
        \(callIdHeader)\r
        \(cseqHeader)\r
        Contact: <\(contactUri())>\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipResponse.utf8))
    }

    private func resendIncomingInviteOk(request: String) {
        guard let inviteMessage = SipMessage.parse(request),
              let offer = SdpOfferAnswer.parse(inviteMessage.body, fallbackHost: AppConfig.sipHost),
              let localAddress = localSdpAddress(),
              let localRtpPort = rtpAudioEngine?.localPort,
              localRtpPort > 0 else {
            sendIncomingInviteNotAcceptable(request: request)
            return
        }
        sendIncomingInviteOk(
            request: request,
            localAddress: localAddress,
            localRtpPort: localRtpPort,
            payloadType: offer.selectedCodecPayload
        )
    }

    private func sendIncomingInviteOk(
        request: String,
        localAddress: (network: String, host: String),
        localRtpPort: UInt16,
        payloadType: UInt8
    ) {
        let lines = request.components(separatedBy: "\r\n")
        var viaHeader = ""
        var fromHeader = ""
        var toHeader = ""
        var callIdHeader = ""
        var cseqHeader = ""
        for line in lines {
            if line.lowercased().starts(with: "via:") { viaHeader = line }
            if line.lowercased().starts(with: "from:") { fromHeader = line }
            if line.lowercased().starts(with: "to:") { toHeader = line }
            if line.lowercased().starts(with: "call-id:") { callIdHeader = line }
            if line.lowercased().starts(with: "cseq:") { cseqHeader = line }
        }
        
        let sdpBody = """
        v=0\r
        o=Tvoice \(Int(Date().timeIntervalSince1970)) 1 IN \(localAddress.network) \(localAddress.host)\r
        s=Tvoice\r
        c=IN \(localAddress.network) \(localAddress.host)\r
        t=0 0\r
        m=audio \(localRtpPort) RTP/AVP \(payloadType) 101\r
        a=rtpmap:\(payloadType) \(payloadType == 0 ? "PCMU/8000" : "PCMA/8000")\r
        a=rtpmap:101 telephone-event/8000\r
        a=fmtp:101 0-16\r
        a=ptime:20\r
        a=sendrecv\r

        """
        let bodyData = Data(sdpBody.utf8)
        let toTag = activeDialog?.localTag ?? String(UUID().uuidString.prefix(8))
        let sipResponse = """
        SIP/2.0 200 OK\r
        \(viaHeader)\r
        \(fromHeader)\r
        \(toHeader.contains("tag=") ? toHeader : "\(toHeader);tag=\(toTag)")\r
        \(callIdHeader)\r
        \(cseqHeader)\r
        Contact: <\(contactUri())>\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Content-Type: application/sdp\r
        Content-Length: \(bodyData.count)\r
        \r
        \(sdpBody)
        """
        send(data: Data(sipResponse.utf8))
    }

    private func sendIncomingInviteReject(request: String) {
        let lines = request.components(separatedBy: "\r\n")
        var viaHeader = ""
        var fromHeader = ""
        var toHeader = ""
        var callIdHeader = ""
        var cseqHeader = ""
        for line in lines {
            if line.lowercased().starts(with: "via:") { viaHeader = line }
            if line.lowercased().starts(with: "from:") { fromHeader = line }
            if line.lowercased().starts(with: "to:") { toHeader = line }
            if line.lowercased().starts(with: "call-id:") { callIdHeader = line }
            if line.lowercased().starts(with: "cseq:") { cseqHeader = line }
        }
        let toTag = activeDialog?.localTag ?? String(UUID().uuidString.prefix(8))
        let sipResponse = """
        SIP/2.0 486 Busy Here\r
        \(viaHeader)\r
        \(fromHeader)\r
        \(toHeader.contains("tag=") ? toHeader : "\(toHeader);tag=\(toTag)")\r
        \(callIdHeader)\r
        \(cseqHeader)\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipResponse.utf8))
    }

    private func sendIncomingInviteNotAcceptable(request: String) {
        sendResponse(status: "488 Not Acceptable Here", request: request, addLocalToTag: true)
    }

    private func sendRequestOk(request: String) {
        sendResponse(status: "200 OK", request: request, addLocalToTag: false)
    }

    private func sendResponse(status: String, request: String, addLocalToTag: Bool) {
        guard let parsed = SipMessage.parse(request),
              let via = parsed.header("Via"),
              let from = parsed.header("From"),
              var to = parsed.header("To"),
              let callID = parsed.header("Call-ID"),
              let cseq = parsed.header("CSeq") else { return }
        if addLocalToTag, !to.lowercased().contains(";tag=") {
            to += ";tag=\(activeDialog?.localTag ?? String(UUID().uuidString.prefix(8)))"
        }
        let response = """
        SIP/2.0 \(status)\r
        Via: \(via)\r
        From: \(from)\r
        To: \(to)\r
        Call-ID: \(callID)\r
        CSeq: \(cseq)\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(response.utf8))
    }

    private func sendInviteChallengeAck(response: String, dialog: SipDialog) {
        guard let parsed = SipMessage.parse(response),
              let from = parsed.header("From"),
              let to = parsed.header("To") else { return }
        let ack = """
        ACK \(dialog.requestURI) SIP/2.0\r
        \(viaHeader(branch: dialog.viaBranch))\r
        Max-Forwards: 70\r
        From: \(from)\r
        To: \(to)\r
        Call-ID: \(dialog.callID)\r
        CSeq: \(dialog.localCSeq) ACK\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(ack.utf8))
    }
    
    private func send(data: Data) {
        logOutgoingSip(data)
        connection?.send(content: data, completion: .contentProcessed({ error in
            if let error {
                print("UDP Send error:", error)
            }
        }))
    }

    private func logOutgoingSip(_ data: Data) {
        guard let message = String(data: data, encoding: .utf8) else { return }
        let firstLine = message.components(separatedBy: CharacterSet.newlines).first ?? ""
        let shouldLog = firstLine.hasPrefix("INVITE ")
            || firstLine.hasPrefix("ACK ")
            || firstLine.hasPrefix("BYE ")
            || firstLine.hasPrefix("CANCEL ")
            || firstLine.hasPrefix("REFER ")
            || firstLine.hasPrefix("SIP/2.0 180")
            || firstLine.hasPrefix("SIP/2.0 200")
            || firstLine.hasPrefix("SIP/2.0 486")
            || firstLine.hasPrefix("SIP/2.0 487")
        guard shouldLog else { return }
        let sanitized = message
            .components(separatedBy: CharacterSet.newlines)
            .map { line -> String in
                let lower = line.lowercased()
                if lower.hasPrefix("authorization:") || lower.hasPrefix("proxy-authorization:") {
                    return line.split(separator: ":", maxSplits: 1).first.map { "\($0): <redacted>" } ?? "<redacted>"
                }
                return line
            }
            .joined(separator: "\r\n")
        print("Sending SIP UDP packet:", sanitized)
    }
}
