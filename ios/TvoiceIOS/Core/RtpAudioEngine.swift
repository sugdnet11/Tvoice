import Foundation
import Network
import AVFoundation

final class RtpAudioEngine {
    private var rtpSocket: DatagramSocket?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isRunning = false
    
    private var ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var sequenceNumber: UInt16 = UInt16.random(in: 1...UInt16.max)
    private var rtpTimestamp: UInt32 = UInt32.random(in: 1...UInt32.max)
    
    private(set) var localPort: UInt16 = 0
    private var remoteEndpoint: InetSocketAddress?
    private var selectedPayloadType: UInt8 = 8 // PCMA by default
    private var isMuted = false
    
    // Decoded audio playback format (8000 Hz Mono Float32 or Int16)
    private let pcm8kFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!
    
    func start(remoteHost: String, remotePort: UInt16, payloadType: UInt8 = 8) throws -> UInt16 {
        stop()
        
        self.selectedPayloadType = payloadType
        self.remoteEndpoint = InetSocketAddress(host: remoteHost, port: remotePort)
        
        // 1. Create bound UDP socket for symmetric RTP I/O on dynamic local port
        let socket = try DatagramSocket()
        self.localPort = socket.localPort
        self.rtpSocket = socket
        self.isRunning = true
        
        // 2. Setup AVAudioEngine for duplex audio
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        
        let mainMixer = engine.mainMixerNode
        let nativeOutputFormat = mainMixer.outputFormat(forBus: 0)
        
        // Connect player to mixer with format conversion
        engine.connect(player, to: mainMixer, format: nativeOutputFormat)
        
        // Setup capture from microphone inputNode
        let inputNode = engine.inputNode
        let nativeInputFormat = inputNode.outputFormat(forBus: 0)
        
        guard let captureConverter = AVAudioConverter(from: nativeInputFormat, to: pcm8kFormat) else {
            throw NSError(domain: "RtpAudioEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create capture AVAudioConverter"])
        }
        
        var sampleAccumulator = [Int16]()
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeInputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRunning, !self.isMuted else { return }
            
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 8000.0 / buffer.format.sampleRate)
            guard frameCount > 0, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: self.pcm8kFormat, frameCapacity: frameCount) else { return }
            
            var error: NSError?
            let status = captureConverter.convert(to: pcmBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if status == .haveData, let channelData = pcmBuffer.int16ChannelData?[0] {
                let count = Int(pcmBuffer.frameLength)
                for i in 0..<count {
                    sampleAccumulator.append(channelData[i])
                    if sampleAccumulator.count >= 160 {
                        let chunk = Array(sampleAccumulator.prefix(160))
                        sampleAccumulator.removeFirst(160)
                        self.sendRtpFrame(pcmSamples: chunk)
                    }
                }
            }
        }
        
        try engine.start()
        player.play()
        
        self.audioEngine = engine
        self.playerNode = player
        
        // 3. Start background UDP socket receiver loop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.receiveLoop()
        }
        
        return self.localPort
    }
    
    func stop() {
        isRunning = false
        audioEngine?.stop()
        audioEngine = nil
        playerNode?.stop()
        playerNode = nil
        rtpSocket?.closeSocket()
        rtpSocket = nil
    }
    
    func setMuted(_ muted: Bool) {
        self.isMuted = muted
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
        
        guard let channelData = pcmBuffer.int16ChannelData?[0] else { return }
        
        payload.withUnsafeBytes { ptr in
            guard let bytes = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            if payloadType == 0 {
                for i in 0..<count {
                    channelData[i] = RtpCodecs.mulawToLinear(bytes[i])
                }
            } else {
                for i in 0..<count {
                    channelData[i] = RtpCodecs.alawToLinear(bytes[i])
                }
            }
        }
        
        if let player = playerNode {
            player.scheduleBuffer(pcmBuffer)
        }
    }
}

// Pure Swift G.711 PCMA / PCMU Codec implementation
enum RtpCodecs {
    static func linearToAlaw(_ pcm: Int16) -> UInt8 {
        let pcmVal = pcm >> 3
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
        return (sign | (exponent << 4) | mantissa) ^ 0xD5
    }

    static func alawToLinear(_ alaw: UInt8) -> Int16 {
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

    static func linearToMulaw(_ pcm: Int16) -> UInt8 {
        var sample = pcm
        let sign: UInt8 = sample < 0 ? 0x80 : 0x00
        if sample < 0 { sample = -sample }
        if sample > 32635 { sample = 32635 }
        sample = sample + 0x84
        var exponent: UInt8 = 7
        var expMask: Int16 = 0x4000
        while (sample & expMask) == 0 && exponent > 0 {
            exponent -= 1
            expMask >>= 1
        }
        let mantissa = UInt8((sample >> (exponent + 3)) & 0x0F)
        let mulaw = ~(sign | (exponent << 4) | mantissa)
        return mulaw
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
}

// Lightweight POSIX UDP DatagramSocket for low-latency RTP
final class DatagramSocket {
    private var socketFd: Int32 = -1
    private(set) var localPort: UInt16 = 0

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
        return (buffer.subdata(in: 0..<readBytes), InetSocketAddress(host: remoteHost, port: remotePort))
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

    var sockaddr: sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_aton(host, &addr.sin_addr)
        return addr
    }
}
