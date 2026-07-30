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
        var payload: UInt8 = 8 // Default PCMA
        
        let lines = sdp.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "c=IN IP4 ") {
                host = trimmed.replacingOccurrences(of: "c=IN IP4 ", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.starts(with: "m=audio ") {
                let parts = trimmed.components(separatedBy: " ")
                if parts.count >= 2, let parsedPort = UInt16(parts[1]) {
                    port = parsedPort
                }
                if parts.count >= 4 {
                    if parts.contains("0") { payload = 0 }
                    else if parts.contains("8") { payload = 8 }
                }
            }
        }
        
        guard let h = host, let p = port else { return nil }
        return SdpOfferAnswer(mediaHost: h, mediaPort: p, selectedCodecPayload: payload)
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
    
    init(direction: Direction, peerNumber: String, callID: String = UUID().uuidString, localTag: String = String(UUID().uuidString.prefix(8))) {
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
}
