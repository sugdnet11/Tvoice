import Foundation
import Network
import AVFoundation
import Darwin

final class RtpAudioEngine {
    enum MediaError: LocalizedError {
        case invalidRemoteEndpoint(String, UInt16)
        case rtpUsesSipPort(UInt16)
        case audioConverterUnavailable

        var errorDescription: String? {
            switch self {
            case let .invalidRemoteEndpoint(host, port):
                return "Некорректный RTP-адрес: \(host):\(port)"
            case let .rtpUsesSipPort(port):
                return "RTP не может использовать SIP-порт \(port)"
            case .audioConverterUnavailable:
                return "Не удалось подготовить преобразование аудио"
            }
        }
    }

    private var rtpSocket: DatagramSocket?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isRunning = false
    private var speakerEnabled = false
    private var isRebuildingAudioGraph = false
    private var notificationTokens = [NSObjectProtocol]()
    private let speakerPlaybackGain: Float = 2.8
    
    private var ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var sequenceNumber: UInt16 = UInt16.random(in: 1...UInt16.max)
    private var rtpTimestamp: UInt32 = UInt32.random(in: 1...UInt32.max)
    
    private(set) var localPort: UInt16 = 0
    private var remoteEndpoint: InetSocketAddress?
    private var selectedPayloadType: UInt8 = 8 // PCMA by default
    private var isMuted = false
    private var isHeld = false
    
    // AVAudioEngine reliably converts this 8 kHz mono Float32 stream to the
    // current hardware format. G.711 conversion still uses Int16 samples.
    private let pcm8kFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!

    /// Binds the symmetric RTP socket before SDP is generated. No media is
    /// sent until `activate` receives the endpoint negotiated in remote SDP.
    @discardableResult
    func prepare() throws -> UInt16 {
        if let socket = rtpSocket, socket.isOpen {
            return localPort
        }

        let socket = try DatagramSocket()
        localPort = socket.localPort
        rtpSocket = socket
        return localPort
    }
    
    func start(remoteHost: String, remotePort: UInt16, payloadType: UInt8 = 8) throws -> UInt16 {
        stop()
        try prepare()
        try activate(remoteHost: remoteHost, remotePort: remotePort, payloadType: payloadType)
        return localPort
    }

    func activate(remoteHost: String, remotePort: UInt16, payloadType: UInt8 = 8) throws {
        guard remotePort != AppConfig.sipPort else {
            throw MediaError.rtpUsesSipPort(remotePort)
        }
        guard remotePort > 0,
              let endpoint = InetSocketAddress(host: remoteHost, port: remotePort) else {
            throw MediaError.invalidRemoteEndpoint(remoteHost, remotePort)
        }
        guard payloadType == 0 || payloadType == 8 else {
            throw MediaError.invalidRemoteEndpoint(remoteHost, remotePort)
        }
        if rtpSocket == nil {
            try prepare()
        }

        self.selectedPayloadType = payloadType
        self.remoteEndpoint = endpoint

        try configureAudioSession(speaker: speakerEnabled)

        self.isRunning = true
        installAudioSessionObservers()
        do {
            try rebuildAudioGraph()
        } catch {
            stop()
            throw error
        }

        // Open the NAT pinhole immediately and give Asterisk symmetric-RTP a
        // valid source before the first microphone callback arrives.
        sendRtpFrame(pcmSamples: Array(repeating: 0, count: 160))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.receiveLoop()
        }
    }
    
    func stop() {
        isRunning = false
        isRebuildingAudioGraph = false
        remoteEndpoint = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        playerNode?.stop()
        playerNode = nil
        rtpSocket?.closeSocket()
        rtpSocket = nil
        localPort = 0
        removeAudioSessionObservers()
    }
    
    func setMuted(_ muted: Bool) {
        self.isMuted = muted
    }

    func setHeld(_ held: Bool) {
        self.isHeld = held
    }

    func setSpeaker(_ enabled: Bool) {
        speakerEnabled = enabled
        do {
            try configureAudioSession(speaker: enabled)
            restartAudioGraphIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.applyCurrentAudioRoute()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.applyCurrentAudioRoute()
            }
        } catch {
            print("Failed to switch audio route:", error)
        }
    }

    func handleSystemAudioSessionActivated() {
        do {
            try configureAudioSession(speaker: speakerEnabled)
            restartAudioGraphIfNeeded()
        } catch {
            print("Failed to restore audio after CallKit activation:", error)
        }
    }

    private func configureAudioSession(speaker: Bool) throws {
        let audioSession = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = speaker
            ? [.allowBluetoothHFP, .defaultToSpeaker]
            : [.allowBluetoothHFP]
        try audioSession.setCategory(.playAndRecord, mode: speaker ? .videoChat : .voiceChat, options: options)
        try audioSession.setPreferredSampleRate(48_000)
        try audioSession.setPreferredIOBufferDuration(0.02)
        try audioSession.setActive(true)
        try audioSession.overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    private func applyCurrentAudioRoute() {
        guard isRunning else { return }
        do {
            try configureAudioSession(speaker: speakerEnabled)
            restartAudioGraphIfNeeded()
        } catch {
            print("Failed to apply audio route:", error)
        }
    }

    private func installAudioSessionObservers() {
        guard notificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.applyCurrentAudioRoute()
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard
                    let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    AVAudioSession.InterruptionType(rawValue: rawType) == .ended
                else { return }
                do {
                    try self?.configureAudioSession(speaker: self?.speakerEnabled == true)
                    try self?.rebuildAudioGraph()
                } catch {
                    print("Failed to resume audio session:", error)
                }
            }
        )
    }

    private func removeAudioSessionObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach { center.removeObserver($0) }
        notificationTokens.removeAll()
    }

    private func restartAudioGraphIfNeeded() {
        guard isRunning else { return }
        do {
            if audioEngine?.isRunning != true || playerNode?.isPlaying != true {
                try rebuildAudioGraph()
            }
        } catch {
            print("Failed to restart audio graph:", error)
        }
    }

    private func rebuildAudioGraph() throws {
        guard isRunning, !isRebuildingAudioGraph else { return }
        isRebuildingAudioGraph = true
        defer { isRebuildingAudioGraph = false }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        playerNode?.stop()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcm8kFormat)
        player.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0

        let inputNode = engine.inputNode
        let nativeInputFormat = inputNode.outputFormat(forBus: 0)
        guard let captureConverter = AVAudioConverter(from: nativeInputFormat, to: pcm8kFormat) else {
            throw MediaError.audioConverterUnavailable
        }

        var sampleAccumulator = [Int16]()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeInputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRunning else { return }

            let frameCount = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 8000.0 / buffer.format.sampleRate))
            guard frameCount > 0,
                  let pcmBuffer = AVAudioPCMBuffer(pcmFormat: self.pcm8kFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            var suppliedInput = false
            _ = captureConverter.convert(to: pcmBuffer, error: &error) { _, outStatus in
                if suppliedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil,
                  pcmBuffer.frameLength > 0,
                  let channelData = pcmBuffer.floatChannelData?[0] else { return }

            let count = Int(pcmBuffer.frameLength)
            for i in 0..<count {
                let scaled = max(-1.0, min(1.0, channelData[i])) * Float(Int16.max)
                sampleAccumulator.append((self.isMuted || self.isHeld) ? 0 : Int16(scaled))
                if sampleAccumulator.count >= 160 {
                    let chunk = Array(sampleAccumulator.prefix(160))
                    sampleAccumulator.removeFirst(160)
                    self.sendRtpFrame(pcmSamples: chunk)
                }
            }
        }

        audioEngine = engine
        playerNode = player
        engine.prepare()
        try engine.start()
        player.play()
        sendRtpFrame(pcmSamples: Array(repeating: 0, count: 160))
    }
    
    private func sendRtpFrame(pcmSamples: [Int16]) {
        guard let socket = rtpSocket, let target = remoteEndpoint else { return }
        
        // Encode PCM 16-bit 8000 Hz to G.711 PCMA (8) or PCMU (0)
        var encodedPayload = Data(capacity: pcmSamples.count)
        if selectedPayloadType == 0 {
            for sample in pcmSamples {
                encodedPayload.append(RtpCodecs.linearToMulaw(sample))
            }
        } else {
            for sample in pcmSamples {
                encodedPayload.append(RtpCodecs.linearToAlaw(sample))
            }
        }
        
        // Construct 12-byte RTP Header
        var packet = Data(count: 12 + encodedPayload.count)
        packet[0] = 0x80 // Version 2
        packet[1] = selectedPayloadType & 0x7F
        
        // Sequence Number (Big Endian)
        let seq = sequenceNumber.bigEndian
        withUnsafeBytes(of: seq) { packet.replaceSubrange(2..<4, with: $0) }
        sequenceNumber = sequenceNumber &+ 1
        
        // Timestamp (Big Endian) - increment by 160 per 20ms frame
        let ts = rtpTimestamp.bigEndian
        withUnsafeBytes(of: ts) { packet.replaceSubrange(4..<8, with: $0) }
        rtpTimestamp = rtpTimestamp &+ 160
        
        // SSRC (Big Endian)
        let s = ssrc.bigEndian
        withUnsafeBytes(of: s) { packet.replaceSubrange(8..<12, with: $0) }
        
        packet.replaceSubrange(12..<(12 + encodedPayload.count), with: encodedPayload)
        
        try? socket.send(data: packet, to: target)
    }
    
    private func receiveLoop() {
        guard let socket = rtpSocket else { return }
        var buffer = Data(count: 2048)
        
        while isRunning {
            do {
                let (receivedData, _) = try socket.receive(into: &buffer)
                guard receivedData.count >= 12 else { continue }
                
                // Parse RTP Header
                let version = (receivedData[0] >> 6) & 0x03
                guard version == 2 else { continue }
                
                let padding = (receivedData[0] & 0x20) != 0
                let extensionPresent = (receivedData[0] & 0x10) != 0
                let cc = Int(receivedData[0] & 0x0F)
                let payloadType = receivedData[1] & 0x7F
                
                var offset = 12 + (cc * 4)
                if extensionPresent, receivedData.count >= offset + 4 {
                    let extLen = Int(UInt16(receivedData[offset + 2]) << 8 | UInt16(receivedData[offset + 3])) * 4
                    offset += 4 + extLen
                }
                
                var endOffset = receivedData.count
                if padding, endOffset > offset {
                    let paddingLen = Int(receivedData[endOffset - 1])
                    endOffset = max(offset, endOffset - paddingLen)
                }
                
                guard offset < endOffset else { continue }
                let payload = receivedData.subdata(in: offset..<endOffset)
                
                guard payloadType == 0 || payloadType == 8 else { continue }
                playReceivedPayload(payload, payloadType: payloadType)
            } catch {
                if !isRunning { break }
            }
        }
    }
    
    private func playReceivedPayload(_ payload: Data, payloadType: UInt8) {
        let count = payload.count
        guard count > 0, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcm8kFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(count)
        
        guard let channelData = pcmBuffer.floatChannelData?[0] else { return }
        
        payload.withUnsafeBytes { ptr in
            guard let bytes = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            if payloadType == 0 {
                for i in 0..<count {
                    channelData[i] = Float(RtpCodecs.mulawToLinear(bytes[i])) / Float(Int16.max)
                }
            } else {
                for i in 0..<count {
                    channelData[i] = Float(RtpCodecs.alawToLinear(bytes[i])) / Float(Int16.max)
                }
            }
        }
        if speakerEnabled {
            for i in 0..<count {
                channelData[i] = max(-1.0, min(1.0, channelData[i] * speakerPlaybackGain))
            }
        }
        
        if !isHeld, let player = playerNode {
            player.scheduleBuffer(pcmBuffer)
        }
    }
}

// Pure Swift G.711 PCMA / PCMU Codec implementation
enum RtpCodecs {
    static func linearToAlaw(_ pcm: Int16) -> UInt8 {
        var sample = Int32(pcm) >> 3
        let mask: UInt8
        if sample >= 0 {
            mask = 0xD5
        } else {
            mask = 0x55
            sample = -sample - 1
        }
        sample = min(sample, 4095)
        let segment = segmentIndex(sample)
        let value: UInt8
        if segment < 2 {
            value = UInt8((segment << 4) | Int((sample >> 1) & 0x0F))
        } else {
            value = UInt8((segment << 4) | Int((sample >> Int32(segment)) & 0x0F))
        }
        return value ^ mask
    }

    static func alawToLinear(_ alaw: UInt8) -> Int16 {
        let value = alaw ^ 0x55
        let segment = Int32((value & 0x70) >> 4)
        var sample = Int32(value & 0x0F) << 4
        switch segment {
        case 0:
            sample += 8
        case 1:
            sample += 0x108
        default:
            sample = (sample + 0x108) << (segment - 1)
        }
        return Int16((value & 0x80) != 0 ? sample : -sample)
    }

    static func linearToMulaw(_ pcm: Int16) -> UInt8 {
        var sample = Int32(pcm)
        let mask: UInt8
        if sample < 0 {
            sample = -sample
            mask = 0x7F
        } else {
            mask = 0xFF
        }
        sample = min(sample + 0x84, 32635)
        var exponent = 7
        var expMask: Int32 = 0x4000
        while exponent > 0 && sample & expMask == 0 {
            exponent -= 1
            expMask >>= 1
        }
        let mantissa = (sample >> Int32(exponent + 3)) & 0x0F
        let value = UInt8((exponent << 4) | Int(mantissa))
        return value ^ mask
    }

    static func mulawToLinear(_ mulaw: UInt8) -> Int16 {
        let u = ~mulaw
        let sign = u & 0x80
        let exponent = (u >> 4) & 0x07
        let mantissa = u & 0x0F
        var sample = Int16((mantissa << 3) + 0x84) << exponent
        sample -= 0x84
        return sign != 0 ? -sample : sample
    }

    private static func segmentIndex(_ sample: Int32) -> Int {
        let segmentEnds: [Int32] = [31, 63, 127, 255, 511, 1023, 2047, 4095]
        return segmentEnds.firstIndex(where: { sample <= $0 }) ?? 7
    }
}

// Lightweight POSIX UDP DatagramSocket for low-latency RTP
final class DatagramSocket {
    private var socketFd: Int32 = -1
    private(set) var localPort: UInt16 = 0
    var isOpen: Bool { socketFd >= 0 }

    init() throws {
        socketFd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFd >= 0 else {
            throw NSError(domain: "DatagramSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }
        
        var reuse = 1
        setsockopt(socketFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        addr.sin_port = 0 // Auto-assign free local port

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindRes == 0 else {
            close(socketFd)
            throw NSError(domain: "DatagramSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to bind socket"])
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(socketFd, withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &len)

        self.localPort = UInt16(bigEndian: addr.sin_port)
    }

    func send(data: Data, to target: InetSocketAddress) throws {
        var addr = target.sockaddr
        _ = data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(socketFd, ptr.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func receive(into buffer: inout Data) throws -> (Data, InetSocketAddress) {
        var srcAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bufferCount = buffer.count
        let readBytes = buffer.withUnsafeMutableBytes { ptr in
            withUnsafeMutablePointer(to: &srcAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(socketFd, ptr.baseAddress, bufferCount, 0, sa, &addrLen)
                }
            }
        }

        guard readBytes > 0 else {
            throw NSError(domain: "DatagramSocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "Recv error"])
        }

        let remoteHost = String(cString: inet_ntoa(srcAddr.sin_addr))
        let remotePort = UInt16(bigEndian: srcAddr.sin_port)
        guard let source = InetSocketAddress(host: remoteHost, port: remotePort) else {
            throw NSError(domain: "DatagramSocket", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid RTP source endpoint"])
        }
        return (buffer.subdata(in: 0..<readBytes), source)
    }

    func closeSocket() {
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
    }

    deinit {
        closeSocket()
    }
}

struct InetSocketAddress {
    let host: String
    let port: UInt16

    init?(host: String, port: UInt16) {
        guard port > 0 else { return nil }
        var parsed = in_addr()
        guard inet_pton(AF_INET, host, &parsed) == 1 else { return nil }
        self.host = host
        self.port = port
    }

    var sockaddr: sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_aton(host, &addr.sin_addr)
        return addr
    }
}
