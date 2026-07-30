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
        headers.first(where: { $0.key.lowercased() == name.lowercased() })?.value.first
    }
    
    func headers(_ name: String) -> [String] {
        headers.first(where: { $0.key.lowercased() == name.lowercased() })?.value ?? []
    }
    
    static func parse(_ raw: String) -> SipMessage? {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 1 else { return nil }
        
        let headerBlock = parts[0]
        let body = parts.count > 1 ? parts[1] : ""
        
        let lines = headerBlock.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else { return nil }
        
        var parsedHeaders = [String: [String]]()
        for i in 1..<lines.count {
            let line = lines[i]
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            parsedHeaders[key, default: []].append(val)
        }
        
        return SipMessage(startLine: firstLine, headers: parsedHeaders, body: body)
    }
}

struct SdpOfferAnswer {
    let mediaHost: String
    let mediaPort: UInt16
    let selectedCodecPayload: UInt8
    
    static func parse(_ sdp: String) -> SdpOfferAnswer? {
        var host: String?
        var port: UInt16?
        var payload: UInt8?
        var insideAudioSection = false
        
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
                    port = parsedPort
                    payload = parts.dropFirst(3).compactMap { UInt8($0) }.first(where: { $0 == 8 || $0 == 0 })
                }
            } else if trimmed.starts(with: "c=IN IP4 "), host == nil || insideAudioSection {
                host = trimmed.replacingOccurrences(of: "c=IN IP4 ", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        
        guard let h = host,
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
        self.viaBranch = "z9hG4bK-\(UUID().uuidString)"
        self.requestURI = "sip:\(peerNumber)@\(AppConfig.sipHost)"
        self.remoteTarget = "sip:\(peerNumber)@\(AppConfig.sipHost)"
        self.routeSet = []
    }

    func update(fromInviteResponse message: SipMessage) {
        remoteTag = Self.parameter(named: "tag", in: message.header("To")) ?? remoteTag
        remoteTarget = Self.uri(in: message.header("Contact")) ?? remoteTarget
        connected = message.statusCode == 200
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
}
