import Foundation

struct SipMessage {
    let startLine: String
    let headers: [String: [String]]
    let body: String
    
    var method: String? {
        let parts = startLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        return parts.first?.uppercased()
    }
    
    var statusCode: Int? {
        let parts = startLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }
    
    func header(_ name: String) -> String? {
        let normalized = name.lowercased()
        let compact: String?
        switch normalized {
        case "via": compact = "v"
        case "from": compact = "f"
        case "to": compact = "t"
        case "call-id": compact = "i"
        case "contact": compact = "m"
        case "content-length": compact = "l"
        case "content-type": compact = "c"
        default: compact = nil
        }
        return headers.first(where: { $0.key.lowercased() == normalized })?.value.first
            ?? compact.flatMap { short in headers.first(where: { $0.key.lowercased() == short })?.value.first }
    }
    
    func headers(_ name: String) -> [String] {
        let normalized = name.lowercased()
        return headers.first(where: { $0.key.lowercased() == normalized })?.value ?? []
    }

    var cseqMethod: String? {
        header("CSeq")?
            .split(separator: " ")
            .last
            .map { String($0).uppercased() }
    }

    var cseqNumber: Int? {
        header("CSeq")?
            .split(separator: " ")
            .first
            .flatMap { Int($0) }
    }
    
    static func parse(_ raw: String) -> SipMessage? {
        let normalizedRaw = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalizedRaw.components(separatedBy: "\n\n")
        
        let headerBlock = parts[0]
        let body = parts.count > 1 ? parts[1] : ""
        
        let lines = headerBlock.components(separatedBy: "\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else { return nil }
        
        var parsedHeaders = [String: [String]]()
        var lastKey: String?
        for i in 1..<lines.count {
            let line = lines[i]
            if (line.starts(with: " ") || line.starts(with: "\t")), let lastKey {
                var values = parsedHeaders[lastKey] ?? []
                if let last = values.indices.last {
                    values[last] += " " + line.trimmingCharacters(in: .whitespaces)
                    parsedHeaders[lastKey] = values
                }
                continue
            }
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            parsedHeaders[key, default: []].append(val)
            lastKey = key
        }
        
        return SipMessage(startLine: firstLine, headers: parsedHeaders, body: body)
    }
}

struct SdpOfferAnswer {
    let mediaHost: String
    let mediaPort: UInt16
    let selectedCodecPayload: UInt8
    
    static func parse(_ sdp: String, fallbackHost: String? = nil) -> SdpOfferAnswer? {
        var host: String?
        var port: UInt16?
        var payload: UInt8?
        var insideAudioSection = false
        var transportSupported = false
        
        let lines = sdp.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "m=") {
                insideAudioSection = trimmed.starts(with: "m=audio ")
                if insideAudioSection {
                    let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    guard parts.count >= 4,
                          let parsedPort = UInt16(parts[1]),
                          parsedPort > 0,
                          parsedPort != AppConfig.sipPort else { return nil }
                    transportSupported = ["RTP/AVP", "RTP/AVPF"].contains(parts[2].uppercased())
                    port = parsedPort
                    payload = parts.dropFirst(3).compactMap { UInt8($0) }.first(where: { $0 == 8 || $0 == 0 })
                }
            } else if trimmed.starts(with: "c=IN IP4 ") || trimmed.starts(with: "c=IN IP6 ") {
                if host == nil || insideAudioSection {
                    host = trimmed
                        .split(separator: " ")
                        .last
                        .map(String.init)?
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        guard transportSupported,
              let h = host ?? fallbackHost,
              h != "0.0.0.0",
              let p = port,
              let selectedPayload = payload else { return nil }
        return SdpOfferAnswer(mediaHost: h, mediaPort: p, selectedCodecPayload: selectedPayload)
    }
}

final class SipDialog {
    enum Direction { case outgoing, incoming }
    
    let direction: Direction
    let peerNumber: String
    let callID: String
    let localTag: String
    var remoteTag: String?
    var localCSeq: Int
    var remoteCSeq: Int
    var viaBranch: String
    var requestURI: String
    var remoteTarget: String
    var routeSet: [String]
    var connected: Bool = false
    var accepted: Bool = false
    
    init(
        direction: Direction,
        peerNumber: String,
        callID: String = "\(UUID().uuidString)@\(AppConfig.sipHost)",
        localTag: String = String(UUID().uuidString.prefix(8))
    ) {
        self.direction = direction
        self.peerNumber = peerNumber
        self.callID = callID
        self.localTag = localTag
        self.localCSeq = 1
        self.remoteCSeq = 0
        self.viaBranch = Self.newBranch()
        self.requestURI = "sip:\(peerNumber)@\(AppConfig.sipHost)"
        self.remoteTarget = "sip:\(peerNumber)@\(AppConfig.sipHost)"
        self.routeSet = []
    }

    func update(fromInviteResponse message: SipMessage) {
        remoteTag = Self.parameter(named: "tag", in: message.header("To")) ?? remoteTag
        remoteTarget = Self.uri(in: message.header("Contact")) ?? remoteTarget
        let routes = message.headers("Record-Route")
        if !routes.isEmpty {
            routeSet = routes.reversed()
        }
        connected = message.statusCode == 200
    }

    func updateEarlyDialog(fromInviteResponse message: SipMessage) {
        remoteTag = Self.parameter(named: "tag", in: message.header("To")) ?? remoteTag
        let routes = message.headers("Record-Route")
        if !routes.isEmpty {
            routeSet = routes.reversed()
        }
    }

    static func incoming(peerNumber: String, request: SipMessage) -> SipDialog? {
        guard let callID = request.header("Call-ID") else { return nil }
        let dialog = SipDialog(direction: .incoming, peerNumber: peerNumber, callID: callID)
        dialog.remoteTag = parameter(named: "tag", in: request.header("From"))
        dialog.remoteTarget = uri(in: request.header("Contact")) ?? dialog.remoteTarget
        dialog.requestURI = request.startLine.split(separator: " ").dropFirst().first.map(String.init) ?? dialog.requestURI
        if let cseq = request.header("CSeq")?.split(separator: " ").first.flatMap({ Int($0) }) {
            dialog.remoteCSeq = cseq
        }
        return dialog
    }

    static func uri(in header: String?) -> String? {
        guard let header else { return nil }
        if let left = header.firstIndex(of: "<"),
           let right = header[left...].firstIndex(of: ">") {
            return String(header[header.index(after: left)..<right])
        }
        return header.split(separator: ";", maxSplits: 1).first.map(String.init)
    }

    static func parameter(named name: String, in header: String?) -> String? {
        guard let header else { return nil }
        let marker = ";\(name)="
        guard let range = header.range(of: marker, options: .caseInsensitive) else { return nil }
        return String(header[range.upperBound...].prefix { $0 != ";" && !$0.isWhitespace })
    }

    static func newBranch() -> String {
        "z9hG4bK-\(randomHex(10))"
    }

    static func randomHex(_ count: Int) -> String {
        let alphabet = Array("0123456789abcdef")
        return String((0..<count).map { _ in alphabet.randomElement() ?? Character("0") })
    }
}
