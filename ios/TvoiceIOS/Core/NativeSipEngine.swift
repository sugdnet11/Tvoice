import Foundation
import Network
import AVFoundation

@MainActor
final class NativeSipEngine: ObservableObject {
    @Published private(set) var isRegistered = false
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
    
    func register(sipNumber: String, password: String) {
        self.ownNumber = sipNumber
        self.ownPassword = password
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
        self.callState = .calling(peer: peer)
        
        let audioSession = AVAudioSession.sharedInstance()
        await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { _ in
                continuation.resume()
            }
        }
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.overrideOutputAudioPort(.speaker)
        try audioSession.setActive(true)
        
        sendSipInvite(to: peer, dialog: dialog)
    }

    func acceptCall() {
        guard case let .incoming(peer) = callState, let invite = incomingInviteMessage else { return }
        let dialog = activeDialog ?? SipDialog(direction: .incoming, peerNumber: peer)
        self.activeDialog = dialog
        self.currentCallPeer = peer
        
        var targetPort: UInt16 = 4000
        var targetHost = AppConfig.sipHost
        var payloadType: UInt8 = 8
        
        if let offer = SdpOfferAnswer.parse(invite) {
            targetHost = offer.mediaHost
            targetPort = offer.mediaPort
            payloadType = offer.selectedCodecPayload
        }
        
        let rtpEngine = RtpAudioEngine()
        self.rtpAudioEngine = rtpEngine
        let boundPort = (try? rtpEngine.start(remoteHost: targetHost, remotePort: targetPort, payloadType: payloadType)) ?? 4000
        
        sendIncomingInviteOk(request: invite, localRtpPort: boundPort, payloadType: payloadType)
        self.callState = .connected(peer: peer)
    }

    func rejectCall() {
        if let invite = incomingInviteMessage {
            sendIncomingInviteReject(request: invite)
        }
        stopRingbackTone()
        rtpAudioEngine?.stop()
        rtpAudioEngine = nil
        self.activeDialog = nil
        self.callState = .idle
        self.incomingInviteMessage = nil
    }
    
    func toggleSpeaker(enabled: Bool) {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    func endCall() {
        stopRingbackTone()
        rtpAudioEngine?.stop()
        rtpAudioEngine = nil
        if case .incoming = callState {
            rejectCall()
            return
        }
        if let dialog = activeDialog {
            sendSipBye(dialog: dialog)
        }
        self.activeDialog = nil
        self.callState = .idle
        self.incomingInviteMessage = nil
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
                    self?.isRegistered = true
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

    private func handleSipMessage(_ message: String) {
        print("Received SIP UDP packet:", message)
        
        // Parse rport received IP mapping from FreePBX Via header if present
        let lines = message.components(separatedBy: "\r\n")
        if let viaLine = lines.first(where: { $0.lowercased().starts(with: "via:") }) {
            let pattern = try? NSRegularExpression(pattern: "received=([^;\\s]+)")
            let nsLine = viaLine as NSString
            if let match = pattern?.firstMatch(in: viaLine, range: NSRange(location: 0, length: nsLine.length)) {
                let receivedIp = nsLine.substring(with: match.range(at: 1))
                if mappedContact == nil {
                    mappedContact = receivedIp
                }
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
            let lines = message.components(separatedBy: "\r\n")
            var callerNumber = "Неизвестный"
            if let fromLine = lines.first(where: { $0.lowercased().starts(with: "from:") }) {
                if let match = fromLine.range(of: "sip:([^@]+)@", options: .regularExpression) {
                    callerNumber = String(fromLine[match]).replacingOccurrences(of: "sip:", with: "").replacingOccurrences(of: "@", with: "")
                }
            }
            self.incomingInviteMessage = message
            self.currentCallPeer = callerNumber
            self.callState = .incoming(peer: callerNumber)
            
            // Send 180 Ringing to FreePBX
            sendIncomingInviteRinging(request: message)
            return
        }

        if message.starts(with: "BYE sip:") || message.starts(with: "CANCEL sip:") {
            stopRingbackTone()
            rtpAudioEngine?.stop()
            rtpAudioEngine = nil
            self.callState = .idle
            self.incomingInviteMessage = nil
            return
        }

        if (message.contains("SIP/2.0 401 Unauthorized") || message.contains("SIP/2.0 407 Proxy Authentication Required")) && message.contains("INVITE") {
            let lines = message.components(separatedBy: "\r\n")
            if case let .calling(peer) = callState,
               let dialog = activeDialog,
               let authLine = lines.first(where: { $0.lowercased().starts(with: "www-authenticate:") || $0.lowercased().starts(with: "proxy-authenticate:") }),
               let challenge = DigestChallenge.parse(authLine) {
                let authHeader = DigestAuth.create(
                    challenge: challenge,
                    username: ownNumber,
                    password: ownPassword,
                    method: "INVITE",
                    uri: "sip:\(peer)@\(AppConfig.sipHost)",
                    nonceCount: 1
                )
                sendAuthenticatedInvite(to: peer, authHeader: authHeader, dialog: dialog)
            }
            return
        }

        if (message.contains("SIP/2.0 401 Unauthorized") || message.contains("SIP/2.0 407 Proxy Authentication Required")) && message.contains("REGISTER") {
            // FreePBX challenged registration! Extract WWW-Authenticate header and reply with Digest MD5 Hash
            if let authLine = lines.first(where: { $0.lowercased().starts(with: "www-authenticate:") || $0.lowercased().starts(with: "proxy-authenticate:") }),
               let challenge = DigestChallenge.parse(authLine) {
                cseq += 1
                nonceCount += 1
                let authHeader = DigestAuth.create(
                    challenge: challenge,
                    username: ownNumber,
                    password: ownPassword,
                    method: "REGISTER",
                    uri: "sip:\(AppConfig.sipHost):5060",
                    nonceCount: nonceCount
                )
                sendAuthenticatedRegister(authHeader: authHeader)
            }
        } else if message.contains("SIP/2.0 200 OK") && message.contains("REGISTER") {
            isRegistered = true
            print("Successfully registered on FreePBX as Available:", ownNumber)
        } else if message.contains("SIP/2.0 180 Ringing") {
            // FreePBX confirmed recipient device is ringing!
            if case let .calling(peer) = callState {
                playRingbackTone()
            }
        } else if message.contains("SIP/2.0 200 OK") && (message.contains("INVITE") || message.contains("CSeq:") && message.contains("INVITE")) {
            // Recipient answered the call! Send ACK to FreePBX to complete three-way handshake
            sendSipAck(response: message)
            stopRingbackTone()
            
            let peerToConnect = currentCallPeer.isEmpty ? "Собеседник" : currentCallPeer
            self.callState = .connected(peer: peerToConnect)
            
            var targetPort: UInt16 = 4000
            var targetHost = AppConfig.sipHost
            var payloadType: UInt8 = 8
            
            if let offer = SdpOfferAnswer.parse(message) {
                targetHost = offer.mediaHost
                targetPort = offer.mediaPort
                payloadType = offer.selectedCodecPayload
            }
            
            if rtpAudioEngine == nil {
                let rtpEngine = RtpAudioEngine()
                self.rtpAudioEngine = rtpEngine
                _ = try? rtpEngine.start(remoteHost: targetHost, remotePort: targetPort, payloadType: payloadType)
            }
        } else if message.contains("SIP/2.0 486 Busy") || message.contains("SIP/2.0 603 Decline") || message.contains("SIP/2.0 487 Request Terminated") {
            stopRingbackTone()
            rtpAudioEngine?.stop()
            rtpAudioEngine = nil
            if case let .calling(peer) = callState {
                LocalCallHistoryStore.saveCall(sipNumber: peer, displayName: peer, direction: "missed", isVideo: false)
            }
            self.callState = .failed(reason: "Занято или вызов отклонен")
        }
    }
    
    private func contactUri() -> String {
        let contactHost = mappedContact ?? AppConfig.sipHost
        return "sip:\(ownNumber)@\(contactHost):5060;transport=udp"
    }

    private func sendSipRegister() {
        cseq = 1
        nonceCount = 1
        let sipMessage = """
        REGISTER sip:\(AppConfig.sipHost):5060 SIP/2.0\r
        Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=z9hG4bK\(UUID().uuidString)\r
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
        Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=z9hG4bK\(UUID().uuidString)\r
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

    private func sendAuthenticatedRegister(authHeader: String) {
        let sipMessage = """
        REGISTER sip:\(AppConfig.sipHost):5060 SIP/2.0\r
        Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=z9hG4bK\(UUID().uuidString)\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(registerTag)\r
        To: <sip:\(ownNumber)@\(AppConfig.sipHost)>\r
        Call-ID: \(registerCallId)\r
        CSeq: \(cseq) REGISTER\r
        Contact: <\(contactUri())>;ob;expires=3600\r
        Authorization: \(authHeader)\r
        Expires: 3600\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipMessage.utf8))
    }
    
    private func sendSipInvite(to peer: String, dialog: SipDialog) {
        let rtpEngine = RtpAudioEngine()
        self.rtpAudioEngine = rtpEngine
        let boundPort = (try? rtpEngine.start(remoteHost: AppConfig.sipHost, remotePort: 5060)) ?? 4000
        
        let sdpBody = """
        v=0\r
        o=Tvoice \(Int(Date().timeIntervalSince1970)) 1 IN IP4 \(AppConfig.sipHost)\r
        s=Tvoice\r
        c=IN IP4 \(AppConfig.sipHost)\r
        t=0 0\r
        m=audio \(boundPort) RTP/AVP 8 0 101\r
        a=rtpmap:8 PCMA/8000\r
        a=rtpmap:0 PCMU/8000\r
        a=rtpmap:101 telephone-event/8000\r
        a=fmtp:101 0-16\r
        a=ptime:20\r
        a=sendrecv\r

        """
        let bodyData = Data(sdpBody.utf8)
        let sipInvite = """
        INVITE sip:\(peer)@\(AppConfig.sipHost) SIP/2.0\r
        Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=\(dialog.viaBranch)\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: <sip:\(peer)@\(AppConfig.sipHost)>\r
        Call-ID: \(dialog.callID)@\(AppConfig.sipHost)\r
        CSeq: \(dialog.localCSeq) INVITE\r
        Contact: <\(contactUri())>\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Content-Type: application/sdp\r
        Content-Length: \(bodyData.count)\r
        \r
        \(sdpBody)
        """
        send(data: Data(sipInvite.utf8))
    }

    private func sendAuthenticatedInvite(to peer: String, authHeader: String, dialog: SipDialog) {
        dialog.localCSeq += 1
        let boundPort = rtpAudioEngine?.localPort ?? 4000
        let sdpBody = """
        v=0\r
        o=Tvoice \(Int(Date().timeIntervalSince1970)) 1 IN IP4 \(AppConfig.sipHost)\r
        s=Tvoice\r
        c=IN IP4 \(AppConfig.sipHost)\r
        t=0 0\r
        m=audio \(boundPort) RTP/AVP 8 0 101\r
        a=rtpmap:8 PCMA/8000\r
        a=rtpmap:0 PCMU/8000\r
        a=rtpmap:101 telephone-event/8000\r
        a=fmtp:101 0-16\r
        a=ptime:20\r
        a=sendrecv\r

        """
        let bodyData = Data(sdpBody.utf8)
        let sipInvite = """
        INVITE sip:\(peer)@\(AppConfig.sipHost) SIP/2.0\r
        Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=\(dialog.viaBranch)\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: <sip:\(peer)@\(AppConfig.sipHost)>\r
        Call-ID: \(dialog.callID)@\(AppConfig.sipHost)\r
        CSeq: \(dialog.localCSeq) INVITE\r
        Contact: <\(contactUri())>\r
        Authorization: \(authHeader)\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Content-Type: application/sdp\r
        Content-Length: \(bodyData.count)\r
        \r
        \(sdpBody)
        """
        send(data: Data(sipInvite.utf8))
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
        ACK sip:\(currentCallPeer)@\(AppConfig.sipHost) SIP/2.0\r
        Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=z9hG4bK\(UUID().uuidString)\r
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
        let remoteTagPart = dialog.remoteTag != nil ? ";tag=\(dialog.remoteTag!)" : ""
        let sipBye = """
        BYE \(dialog.remoteTarget) SIP/2.0\r
        Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=\(dialog.viaBranch)\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(dialog.localTag)\r
        To: <sip:\(dialog.peerNumber)@\(AppConfig.sipHost)>\(remoteTagPart)\r
        Call-ID: \(dialog.callID)@\(AppConfig.sipHost)\r
        CSeq: \(dialog.localCSeq) BYE\r
        Max-Forwards: 70\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipBye.utf8))
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
        let sipResponse = """
        SIP/2.0 180 Ringing\r
        \(viaHeader)\r
        \(fromHeader)\r
        \(toHeader);tag=\(UUID().uuidString.prefix(8))\r
        \(callIdHeader)\r
        \(cseqHeader)\r
        Contact: <\(contactUri())>\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipResponse.utf8))
    }

    private func sendIncomingInviteOk(request: String, localRtpPort: UInt16, payloadType: UInt8) {
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
        let sdpBody = """
        v=0\r
        o=Tvoice \(Int(Date().timeIntervalSince1970)) 1 IN IP4 \(AppConfig.sipHost)\r
        s=Tvoice\r
        c=IN IP4 \(AppConfig.sipHost)\r
        t=0 0\r
        m=audio \(localRtpPort) RTP/AVP \(payloadType) 101\r
        a=rtpmap:\(payloadType) \(payloadType == 0 ? "PCMU/8000" : "PCMA/8000")\r
        a=rtpmap:101 telephone-event/8000\r
        a=fmtp:101 0-16\r
        a=ptime:20\r
        a=sendrecv\r

        """
        let bodyData = Data(sdpBody.utf8)
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
        let sipResponse = """
        SIP/2.0 486 Busy Here\r
        \(viaHeader)\r
        \(fromHeader)\r
        \(toHeader);tag=\(UUID().uuidString.prefix(8))\r
        \(callIdHeader)\r
        \(cseqHeader)\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Content-Length: 0\r
        \r

        """
        send(data: Data(sipResponse.utf8))
    }
    
    private func send(data: Data) {
        connection?.send(content: data, completion: .contentProcessed({ error in
            if let error {
                print("UDP Send error:", error)
            }
        }))
    }
}
