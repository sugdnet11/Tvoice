import Foundation
import Network
import AVFoundation

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
    private var registerCallId = UUID().uuidString
    private var registerTag = String(UUID().uuidString.prefix(8))
    private var cseq = 1
    private var nonceCount = 1
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
        connectUDP()
    }
    
    func unregister() {
        sendSipUnregister()
        connection?.cancel()
        connection = nil
        isRegistered = false
    }

    func setMuted(_ muted: Bool) {
        rtpAudioEngine?.setMuted(muted)
    }
    
    func startAudioCall(peer: String) async throws {
        let dialog = SipDialog(direction: .outgoing, peerNumber: peer)
        self.activeDialog = dialog
        self.currentCallPeer = peer
        self.currentCallID = dialog.callID
        self.callState = .calling(peer: peer)
        
        let audioSession = AVAudioSession.sharedInstance()
        await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { _ in
                continuation.resume()
            }
        }
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try audioSession.overrideOutputAudioPort(.none)
        try audioSession.setActive(true)
        
        try sendSipInvite(to: peer, dialog: dialog)
    }

    func acceptCall() {
        guard case let .incoming(peer) = callState, let invite = incomingInviteMessage else { return }
        let dialog = activeDialog ?? SipDialog(direction: .incoming, peerNumber: peer)
        self.activeDialog = dialog
        self.currentCallPeer = peer
        
        guard let offer = SdpOfferAnswer.parse(invite),
              let localAddress = localSdpAddress() else {
            sendIncomingInviteNotAcceptable(request: invite)
            callState = .failed(reason: "FreePBX не передал корректный RTP-адрес")
            return
        }

        let rtpEngine = RtpAudioEngine()
        self.rtpAudioEngine = rtpEngine
        do {
            let boundPort = try rtpEngine.start(
                remoteHost: offer.mediaHost,
                remotePort: offer.mediaPort,
                payloadType: offer.selectedCodecPayload
            )
            printMediaRoute(localHost: localAddress.host, localPort: boundPort, offer: offer)
            sendIncomingInviteOk(
                request: invite,
                localAddress: localAddress,
                localRtpPort: boundPort,
                payloadType: offer.selectedCodecPayload
            )
            dialog.connected = true
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
        dialog.viaBranch = "z9hG4bK-\(UUID().uuidString)"
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
    
    private func playRingbackTone() {
        stopRingbackTone()
        // Generate standard SIP ringback tone: 1.5 seconds of 425Hz tone + 2.5 seconds of silence (4-second cycle)
        let sampleRate = 44100.0
        let toneFrequency = 425.0
        let toneDuration = 1.5
        let totalDuration = 4.0
        let totalSamples = Int(sampleRate * totalDuration)
        let toneSamples = Int(sampleRate * toneDuration)
        
        var samples = [Int16]()
        samples.reserveCapacity(totalSamples)
        
        for i in 0..<totalSamples {
            if i < toneSamples {
                let t = Double(i) / sampleRate
                let val = sin(2.0 * Double.pi * toneFrequency * t)
                samples.append(Int16(val * 16384.0))
            } else {
                samples.append(0) // Silence for 2.5 seconds
            }
        }
        
        let data = Data(bytes: samples, count: totalSamples * 2)
        
        // Create WAV header
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
        var sRate = UInt32(44100).littleEndian
        wavHeader.append(Data(bytes: &sRate, count: 4))
        var byteRate = UInt32(44100 * 2).littleEndian
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
        
        do {
            ringbackPlayer = try AVAudioPlayer(data: fullWav)
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
                self?.listenUDP()
            }
        }
    }

    private var mappedContact: String?
    private var mappedContactPort: UInt16?

    private func handleSipMessage(_ message: String) {
        print("Received SIP UDP packet:", message)
        
        // Parse rport received IP mapping from FreePBX Via header if present
        let lines = message.components(separatedBy: "\r\n")
        let cseqMethod = Self.cseqMethod(in: lines)
        if let viaLine = lines.first(where: { $0.lowercased().starts(with: "via:") }) {
            let pattern = try? NSRegularExpression(pattern: "received=([^;\\s]+)")
            let nsLine = viaLine as NSString
            if let match = pattern?.firstMatch(in: viaLine, range: NSRange(location: 0, length: nsLine.length)) {
                let receivedIp = nsLine.substring(with: match.range(at: 1))
                if mappedContact == nil {
                    mappedContact = receivedIp
                }
            }
            let rportPattern = try? NSRegularExpression(pattern: "rport=(\\d+)")
            if let match = rportPattern?.firstMatch(in: viaLine, range: NSRange(location: 0, length: nsLine.length)),
               let port = UInt16(nsLine.substring(with: match.range(at: 1))) {
                mappedContactPort = port
            }
        }

        if message.contains("OPTIONS sip:") {
            // FreePBX sent an OPTIONS keep-alive probe! Automatically reply with 200 OK
            let lines = message.components(separatedBy: "\r\n")
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
            let optionsResponse = """
            SIP/2.0 200 OK\r
            \(viaHeader)\r
            \(fromHeader)\r
            \(toHeader);tag=\(UUID().uuidString.prefix(8))\r
            \(callIdHeader)\r
            \(cseqHeader)\r
            Contact: <\(contactUri())>\r
            Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
            User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
            Content-Length: 0\r
            \r

            """
            send(data: Data(optionsResponse.utf8))
            return
        }

        if message.starts(with: "INVITE sip:") {
            // Incoming Call from FreePBX! Extract Caller SIP number
            guard let parsedRequest = SipMessage.parse(message),
                  let dialog = SipDialog.incoming(peerNumber: "", request: parsedRequest) else {
                sendIncomingInviteNotAcceptable(request: message)
                return
            }
            if let activeDialog, activeDialog.callID == dialog.callID {
                incomingInviteMessage = message
                if activeDialog.connected, activeDialog.accepted {
                    resendIncomingInviteOk(request: message)
                } else {
                    sendIncomingInviteRinging(request: message)
                }
                return
            }
            if activeDialog != nil || rtpAudioEngine != nil {
                sendIncomingInviteReject(request: message)
                return
            }
            let lines = message.components(separatedBy: "\r\n")
            var callerNumber = "Неизвестный"
            if let fromLine = lines.first(where: { $0.lowercased().starts(with: "from:") }) {
                if let match = fromLine.range(of: "sip:([^@]+)@", options: .regularExpression) {
                    callerNumber = String(fromLine[match]).replacingOccurrences(of: "sip:", with: "").replacingOccurrences(of: "@", with: "")
                }
            }
            self.incomingInviteMessage = message
            self.currentCallPeer = callerNumber
            self.activeDialog = SipDialog.incoming(peerNumber: callerNumber, request: parsedRequest)
            self.currentCallID = dialog.callID
            self.callState = .incoming(peer: callerNumber)
            
            // Send 180 Ringing to FreePBX
            sendIncomingInviteRinging(request: message)
            return
        }

        if message.starts(with: "BYE sip:") || message.starts(with: "CANCEL sip:") {
            sendRequestOk(request: message)
            resetCurrentCall()
            return
        }

        if (message.contains("SIP/2.0 401 Unauthorized") || message.contains("SIP/2.0 407 Proxy Authentication Required")) && cseqMethod == "INVITE" {
            if case let .calling(peer) = callState,
               let dialog = activeDialog,
               let authLine = lines.first(where: { $0.lowercased().starts(with: "www-authenticate:") || $0.lowercased().starts(with: "proxy-authenticate:") }),
               let challenge = DigestChallenge.parse(authLine) {
                sendInviteChallengeAck(response: message, dialog: dialog)
                dialog.localCSeq += 1
                dialog.viaBranch = "z9hG4bK-\(UUID().uuidString)"
                let authHeaderName = message.contains("SIP/2.0 407 Proxy Authentication Required")
                    ? "Proxy-Authorization"
                    : "Authorization"
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
            }
            return
        }

        if (message.contains("SIP/2.0 401 Unauthorized") || message.contains("SIP/2.0 407 Proxy Authentication Required")) && cseqMethod == "REGISTER" {
            // FreePBX challenged registration! Extract WWW-Authenticate header and reply with Digest MD5 Hash
            if let authLine = lines.first(where: { $0.lowercased().starts(with: "www-authenticate:") || $0.lowercased().starts(with: "proxy-authenticate:") }),
               let challenge = DigestChallenge.parse(authLine) {
                cseq += 1
                nonceCount += 1
                let authHeaderName = message.contains("SIP/2.0 407 Proxy Authentication Required")
                    ? "Proxy-Authorization"
                    : "Authorization"
                let authHeader = DigestAuth.create(
                    challenge: challenge,
                    username: ownNumber,
                    password: ownPassword,
                    method: "REGISTER",
                    uri: "sip:\(AppConfig.sipHost):5060",
                    nonceCount: nonceCount
                )
                sendAuthenticatedRegister(authHeaderName: authHeaderName, authHeader: authHeader)
            }
        } else if message.contains("SIP/2.0 200 OK") && cseqMethod == "REGISTER" {
            isRegistered = true
            print("Successfully registered on FreePBX as Available:", ownNumber)
        } else if message.contains("SIP/2.0 180 Ringing") && cseqMethod == "INVITE" {
            // FreePBX confirmed recipient device is ringing!
            if case let .calling(peer) = callState {
                playRingbackTone()
            }
        } else if message.contains("SIP/2.0 200 OK") && cseqMethod == "INVITE" {
            guard let response = SipMessage.parse(message),
                  let offer = SdpOfferAnswer.parse(response.body) else {
                stopRingbackTone()
                rtpAudioEngine?.stop()
                rtpAudioEngine = nil
                callState = .failed(reason: "В ответе FreePBX отсутствует корректный SDP/RTP")
                return
            }

            activeDialog?.update(fromInviteResponse: response)
            sendSipAck(response: message)
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
        } else if cseqMethod == "INVITE" && (message.contains("SIP/2.0 486 Busy") || message.contains("SIP/2.0 603 Decline") || message.contains("SIP/2.0 487 Request Terminated")) {
            stopRingbackTone()
            resetCurrentCall()
            if case let .calling(peer) = callState {
                LocalCallHistoryStore.saveCall(sipNumber: peer, displayName: peer, direction: "missed", isVideo: false)
            }
            self.callState = .failed(reason: "Занято или вызов отклонен")
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
    
    private func contactUri() -> String {
        let local = localSignalingEndpoint()
        let contactHost = mappedContact ?? local?.host ?? "0.0.0.0"
        let contactPort = mappedContactPort ?? local?.port ?? AppConfig.sipPort
        return "sip:\(ownNumber)@\(contactHost):\(contactPort);transport=udp"
    }

    private func localSignalingEndpoint() -> (host: String, port: UInt16)? {
        guard let endpoint = connection?.currentPath?.localEndpoint,
              case let .hostPort(host, port) = endpoint else { return nil }
        return (host.debugDescription, port.rawValue)
    }

    private func localSdpAddress() -> (network: String, host: String)? {
        let candidate = localSignalingEndpoint()?.host ?? mappedContact
        guard let candidate,
              candidate != "0.0.0.0",
              candidate != AppConfig.sipHost else { return nil }
        return (candidate.contains(":") ? "IP6" : "IP4", candidate)
    }

    private func viaHeader(branch: String) -> String {
        let local = localSignalingEndpoint()
        let host = local?.host ?? "0.0.0.0"
        let port = local?.port ?? AppConfig.sipPort
        return "Via: SIP/2.0/UDP \(host):\(port);rport;branch=\(branch)"
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

    private func sendSipRegister() {
        cseq = 1
        nonceCount = 1
        let sipMessage = """
        REGISTER sip:\(AppConfig.sipHost):5060 SIP/2.0\r
        \(viaHeader(branch: "z9hG4bK\(UUID().uuidString)"))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(registerTag)\r
        To: <sip:\(ownNumber)@\(AppConfig.sipHost)>\r
        Call-ID: \(registerCallId)\r
        CSeq: \(cseq) REGISTER\r
        Contact: <\(contactUri())>;ob;expires=3600\r
        Expires: 3600\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipMessage.utf8))
    }

    private func sendSipUnregister() {
        cseq += 1
        let sipMessage = """
        REGISTER sip:\(AppConfig.sipHost):5060 SIP/2.0\r
        \(viaHeader(branch: "z9hG4bK\(UUID().uuidString)"))\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(registerTag)\r
        To: <sip:\(ownNumber)@\(AppConfig.sipHost)>\r
        Call-ID: \(registerCallId)\r
        CSeq: \(cseq) REGISTER\r
        Contact: *\r
        Expires: 0\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipMessage.utf8))
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
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE, REFER\r
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
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE, REFER\r
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
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE, REFER\r
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
        dialog.viaBranch = "z9hG4bK-\(UUID().uuidString)"
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

    private func sendSipAck(response: String) {
        let lines = response.components(separatedBy: "\r\n")
        var fromHeader = ""
        var toHeader = ""
        var callIdHeader = ""
        var cseqHeader = ""
        for line in lines {
            if line.lowercased().starts(with: "from:") { fromHeader = line }
            if line.lowercased().starts(with: "to:") { toHeader = line }
            if line.lowercased().starts(with: "call-id:") { callIdHeader = line }
            if line.lowercased().starts(with: "cseq:") { cseqHeader = line }
        }
        
        var cseqNum = "3"
        let pattern = try? NSRegularExpression(pattern: "cseq:\\s*(\\d+)", options: .caseInsensitive)
        let nsHeader = cseqHeader as NSString
        if let match = pattern?.firstMatch(in: cseqHeader, range: NSRange(location: 0, length: nsHeader.length)) {
            cseqNum = nsHeader.substring(with: match.range(at: 1))
        }

        let sipAck = """
        ACK \(activeDialog?.remoteTarget ?? "sip:\(currentCallPeer)@\(AppConfig.sipHost)") SIP/2.0\r
        \(viaHeader(branch: "z9hG4bK\(UUID().uuidString)"))\r
        Max-Forwards: 70\r
        \(fromHeader)\r
        \(toHeader)\r
        \(callIdHeader)\r
        CSeq: \(cseqNum) ACK\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipAck.utf8))
    }
    
    private func sendSipBye(dialog: SipDialog) {
        dialog.localCSeq += 1
        dialog.viaBranch = "z9hG4bK-\(UUID().uuidString)"
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
        guard let offer = SdpOfferAnswer.parse(request),
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
        connection?.send(content: data, completion: .contentProcessed({ error in
            if let error {
                print("UDP Send error:", error)
            }
        }))
    }
}
