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
    
    func register(sipNumber: String, password: String) {
        self.ownNumber = sipNumber
        self.ownPassword = password
        connectUDP()
    }
    
    func startAudioCall(peer: String) async throws {
        self.currentCallPeer = peer
        self.callState = .calling(peer: peer)
        
        // Setup Audio Session explicitly for Loudspeaker / Earpiece Output
        let audioSession = AVAudioSession.sharedInstance()
        await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { _ in
                continuation.resume()
            }
        }
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.overrideOutputAudioPort(.speaker)
        try audioSession.setActive(true)
        
        // Send SIP INVITE to FreePBX 185.177.2.115:5060 over UDP
        sendSipInvite(to: peer)
    }

    func acceptCall() {
        guard case let .incoming(peer) = callState, let invite = incomingInviteMessage else { return }
        self.currentCallPeer = peer
        self.callState = .connected(peer: peer)
        
        // Parse dynamic SDP m=audio port from incoming INVITE
        var targetPort: UInt16 = 4000
        let pattern = try? NSRegularExpression(pattern: "m=audio\\s+(\\d+)")
        let nsMessage = invite as NSString
        if let match = pattern?.firstMatch(in: invite, range: NSRange(location: 0, length: nsMessage.length)),
           let parsedPort = UInt16(nsMessage.substring(with: match.range(at: 1))) {
            targetPort = parsedPort
        }
        
        // Send 200 OK to FreePBX
        sendIncomingInviteOk(request: invite)
        startRtpAudioSession(remotePort: targetPort)
    }

    func rejectCall() {
        if let invite = incomingInviteMessage {
            sendIncomingInviteReject(request: invite)
        }
        self.callState = .idle
        self.incomingInviteMessage = nil
    }
    
    func toggleSpeaker(enabled: Bool) {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    func endCall() {
        stopRingbackTone()
        stopRtpAudioSession()
        if case .incoming = callState {
            rejectCall()
            return
        }
        sendSipBye()
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
            stopRtpAudioSession()
            self.callState = .idle
            self.incomingInviteMessage = nil
            return
        }

        if (message.contains("SIP/2.0 401 Unauthorized") || message.contains("SIP/2.0 407 Proxy Authentication Required")) && message.contains("CSeq: 2 INVITE") {
            // FreePBX challenged the INVITE! Reply with ACK and re-send INVITE with Digest Authorization header
            let lines = message.components(separatedBy: "\r\n")
            if case let .calling(peer) = callState,
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
                sendAuthenticatedInvite(to: peer, authHeader: authHeader)
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
            
            let peerToConnect: String
            if case let .calling(peer) = callState {
                peerToConnect = peer
            } else if case let .incoming(peer) = callState {
                peerToConnect = peer
            } else {
                peerToConnect = currentCallPeer.isEmpty ? "Собеседник" : currentCallPeer
            }
            
            self.callState = .connected(peer: peerToConnect)
            
            // Parse dynamic audio port from SDP "m=audio PORT RTP/AVP"
            var targetPort: UInt16 = 4000
            let pattern = try? NSRegularExpression(pattern: "m=audio\\s+(\\d+)")
            let nsMessage = message as NSString
            if let match = pattern?.firstMatch(in: message, range: NSRange(location: 0, length: nsMessage.length)),
               let parsedPort = UInt16(nsMessage.substring(with: match.range(at: 1))) {
                targetPort = parsedPort
            }
            print("Connecting RTP Voice Stream to FreePBX audio port:", targetPort)
            startRtpAudioSession(remotePort: targetPort)
        } else if message.contains("SIP/2.0 486 Busy") || message.contains("SIP/2.0 603 Decline") || message.contains("SIP/2.0 487 Request Terminated") {
            stopRingbackTone()
            stopRtpAudioSession()
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
    
    private func sendSipInvite(to peer: String) {
        let callId = UUID().uuidString
        let sdpBody = """
        v=0\r
        o=Tvoice \(Int(Date().timeIntervalSince1970)) 1 IN IP4 \(AppConfig.sipHost)\r
        s=Tvoice\r
        c=IN IP4 \(AppConfig.sipHost)\r
        t=0 0\r
        m=audio 4000 RTP/AVP 8 0 101\r
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
        Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=z9hG4bK\(UUID().uuidString)\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(UUID().uuidString.prefix(8))\r
        To: <sip:\(peer)@\(AppConfig.sipHost)>\r
        Call-ID: \(callId)@\(AppConfig.sipHost)\r
        CSeq: 2 INVITE\r
        Contact: <sip:\(ownNumber)@0.0.0.0:5060>\r
        User-Agent: Tvoice/1.0.0 TvoiceSipCore/1.8\r
        Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE\r
        Content-Type: application/sdp\r
        Content-Length: \(bodyData.count)\r
        \r
        \(sdpBody)
        """
        send(data: Data(sipInvite.utf8))
    }

    private func sendAuthenticatedInvite(to peer: String, authHeader: String) {
        let callId = UUID().uuidString
        let sdpBody = """
        v=0\r
        o=Tvoice \(Int(Date().timeIntervalSince1970)) 1 IN IP4 \(AppConfig.sipHost)\r
        s=Tvoice\r
        c=IN IP4 \(AppConfig.sipHost)\r
        t=0 0\r
        m=audio 4000 RTP/AVP 8 0 101\r
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
        Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=z9hG4bK\(UUID().uuidString)\r
        Max-Forwards: 70\r
        From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(UUID().uuidString.prefix(8))\r
        To: <sip:\(peer)@\(AppConfig.sipHost)>\r
        Call-ID: \(callId)@\(AppConfig.sipHost)\r
        CSeq: 3 INVITE\r
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
    
    private func sendSipBye() {
        if case .connected(let peer) = callState {
            let sipBye = """
            BYE sip:\(peer)@\(AppConfig.sipHost) SIP/2.0\r
            Via: SIP/2.0/UDP 0.0.0.0:5060;rport;branch=z9hG4bK\(UUID().uuidString)\r
            From: <sip:\(ownNumber)@\(AppConfig.sipHost)>;tag=\(UUID().uuidString.prefix(8))\r
            To: <sip:\(peer)@\(AppConfig.sipHost)>\r
            Call-ID: \(UUID().uuidString)@\(AppConfig.sipHost)\r
            CSeq: 3 BYE\r
            Max-Forwards: 70\r
            Content-Length: 0\r
            \r

            """
            send(data: Data(sipBye.utf8))
        }
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

    private func sendIncomingInviteOk(request: String) {
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
        o=Tvoice \(Int(Date().timeIntervalSince1970)) 1 IN IP4 \(AppConfig.sipHost)\r
        s=Tvoice\r
        c=IN IP4 \(AppConfig.sipHost)\r
        t=0 0\r
        m=audio 4000 RTP/AVP 8 0 101\r
        a=rtpmap:8 PCMA/8000\r
        a=rtpmap:0 PCMU/8000\r
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
        \(toHeader);tag=\(UUID().uuidString.prefix(8))\r
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
    
    private var rtpConnection: NWConnection?
    private var audioEngine: AVAudioEngine?
    
    private func startRtpAudioSession(remotePort: UInt16) {
        stopRtpAudioSession()
        
        // Setup UDP RTP socket on dynamic FreePBX audio port (e.g. 15502)
        let host = NWEndpoint.Host(AppConfig.sipHost)
        let port = NWEndpoint.Port(rawValue: remotePort) ?? NWEndpoint.Port(rawValue: 4000)!
        
        let rtpConn = NWConnection(host: host, port: port, using: .udp)
        rtpConn.start(queue: .global(qos: .userInitiated))
        self.rtpConnection = rtpConn
        
        // Setup AVAudioEngine for duplex microphone input & speaker output (8000Hz G.711 PCMA)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let outputNode = engine.mainMixerNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!
        
        inputNode.installTap(onBus: 0, bufferSize: 160, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.int16ChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            
            // Encode PCM 16-bit to G.711 A-law (PCMA)
            var pcmaBytes = [UInt8]()
            pcmaBytes.reserveCapacity(frameLength)
            for i in 0..<frameLength {
                let pcmSample = channelData[i]
                pcmaBytes.append(Self.linearToAlaw(pcmSample))
            }
            
            // Send RTP packet (12-byte header + PCMA payload)
            self?.sendRtpPacket(payload: Data(pcmaBytes))
        }
        
        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            print("Failed to start AVAudioEngine:", error)
        }
        
        listenRtp(on: rtpConn, format: format)
    }
    
    private func stopRtpAudioSession() {
        audioEngine?.stop()
        audioEngine = nil
        rtpConnection?.cancel()
        rtpConnection = nil
    }
    
    private func sendRtpPacket(payload: Data) {
        var header = Data(count: 12)
        header[0] = 0x80 // Version 2
        header[1] = 0x08 // Payload type 8 (PCMA G.711 A-law)
        // Sequence number & timestamp
        let seq = UInt16.random(in: 1...65535).bigEndian
        let ts = UInt32(Date().timeIntervalSince1970 * 8000).bigEndian
        withUnsafeBytes(of: seq) { header.replaceSubrange(2..<4, with: $0) }
        withUnsafeBytes(of: ts) { header.replaceSubrange(4..<8, with: $0) }
        
        var packet = header
        packet.append(payload)
        
        rtpConnection?.send(content: packet, completion: .contentProcessed({ _ in }))
    }
    
    private func listenRtp(on conn: NWConnection, format: AVAudioFormat) {
        conn.receiveMessage { [weak self, weak conn] content, _, _, error in
            if let data = content, data.count > 12 {
                let payload = data.subdata(in: 12..<data.count)
                self?.playReceivedRtpAudio(payload: payload, format: format)
            }
            if error == nil, let conn {
                self?.listenRtp(on: conn, format: format)
            }
        }
    }
    
    private func playReceivedRtpAudio(payload: Data, format: AVAudioFormat) {
        // Decode G.711 PCMA bytes back to PCM 16-bit buffer
        let count = payload.count
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(count)
        guard let channelData = pcmBuffer.int16ChannelData?[0] else { return }
        
        payload.withUnsafeBytes { ptr in
            guard let bytes = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<count {
                channelData[i] = Self.alawToLinear(bytes[i])
            }
        }
    }

    // G.711 A-law Codec conversion tables
    private static func linearToAlaw(_ pcm: Int16) -> UInt8 {
        let pcmVal = pcm >> 3
        var mask: UInt8 = 0x00
        var sign: UInt8 = 0x00
        var sample = pcmVal
        if sample < 0 {
            sample = -sample
            sign = 0x80
        }
        if sample > 32512 { sample = 32512 }
        var exponent: UInt8 = 7
        var expMask: Int16 = 0x4000
        while (sample & expMask) == 0 && exponent > 0 {
            exponent -= 1
            expMask >>= 1
        }
        let mantissa = UInt8((sample >> (exponent == 0 ? 4 : exponent + 3)) & 0x0F)
        let alaw = sign | (exponent << 4) | mantissa
        return alaw ^ 0xD5
    }

    private static func alawToLinear(_ alaw: UInt8) -> Int16 {
        var val = Int16(alaw ^ 0xD5)
        var sign: Int16 = 0x00
        if (val & 0x80) != 0 {
            val &= 0x7F
            sign = -1
        }
        let exponent = Int16((val >> 4) & 0x07)
        let mantissa = Int16(val & 0x0F)
        var sample: Int16 = 0
        if exponent == 0 {
            sample = (mantissa << 4) + 8
        } else {
            sample = ((mantissa << 4) + 0x108) << (exponent - 1)
        }
        return sign == 0 ? sample : -sample
    }

    private func send(data: Data) {
        connection?.send(content: data, completion: .contentProcessed({ error in
            if let error {
                print("UDP Send error:", error)
            }
        }))
    }
}
