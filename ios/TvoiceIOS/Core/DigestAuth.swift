import Foundation
import CryptoKit

struct DigestChallenge {
    let realm: String
    let nonce: String
    let qop: String?
    let opaque: String?
    let algorithm: String

    static func parse(_ value: String) -> DigestChallenge? {
        let source = value.replacingOccurrences(of: "Digest", with: "").trimmingCharacters(in: .whitespaces)
        var fields = [String: String]()
        
        let pattern = try? NSRegularExpression(pattern: "([A-Za-z0-9_-]+)\\s*=\\s*(?:\"([^\"]*)\"|([^,\\s]+))")
        let nsSource = source as NSString
        let matches = pattern?.matches(in: source, range: NSRange(location: 0, length: nsSource.length)) ?? []
        
        for match in matches {
            let key = nsSource.substring(with: match.range(at: 1)).lowercased()
            let val1 = match.range(at: 2).location != NSNotFound ? nsSource.substring(with: match.range(at: 2)) : ""
            let val2 = match.range(at: 3).location != NSNotFound ? nsSource.substring(with: match.range(at: 3)) : ""
            fields[key] = val1.isEmpty ? val2 : val1
        }
        
        guard let realm = fields["realm"], let nonce = fields["nonce"] else { return nil }
        let qop = fields["qop"]?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.lowercased() == "auth" }
        return DigestChallenge(realm: realm, nonce: nonce, qop: qop, opaque: fields["opaque"], algorithm: fields["algorithm"] ?? "MD5")
    }
}

enum DigestAuth {
    static func create(
        challenge: DigestChallenge,
        username: String,
        password: String,
        method: String,
        uri: String,
        nonceCount: Int
    ) -> String {
        let nc = String(format: "%08x", nonceCount)
        let cnonce = String(UUID().uuidString.prefix(8).lowercased())
        
        let ha1 = md5("\(username):\(challenge.realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        
        let response: String
        if let qop = challenge.qop {
            response = md5("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        } else {
            response = md5("\(ha1):\(challenge.nonce):\(ha2)")
        }
        
        var header = "Digest username=\"\(username)\", realm=\"\(challenge.realm)\", nonce=\"\(challenge.nonce)\", uri=\"\(uri)\", response=\"\(response)\", algorithm=MD5"
        if let qop = challenge.qop {
            header += ", qop=\(qop), nc=\(nc), cnonce=\"\(cnonce)\""
        }
        if let opaque = challenge.opaque {
            header += ", opaque=\"\(opaque)\""
        }
        return header
    }

    private static func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
