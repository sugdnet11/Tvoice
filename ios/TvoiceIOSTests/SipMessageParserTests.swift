import XCTest
@testable import TvoiceIOS

final class SipMessageParserTests: XCTestCase {

    func testParseResponseMessage() {
        let raw = "SIP/2.0 200 OK\r\nVia: SIP/2.0/UDP 0.0.0.0:5060;branch=z9hG4bK0928\r\nFrom: <sip:78088@185.177.2.115>;tag=8\r\nTo: <sip:73302@185.177.2.115>;tag=12345\r\nCall-ID: 8C9D91D6-66D7-42D2-937F-EEB592B1BEFF\r\nCSeq: 3 INVITE\r\nContent-Type: application/sdp\r\nContent-Length: 15\r\n\r\nv=0\r\nm=audio 15502 RTP/AVP 8 0 101"

        guard let msg = SipMessage.parse(raw) else {
            XCTFail("Failed to parse SIP message")
            return
        }

        XCTAssertEqual(msg.statusCode, 200)
        XCTAssertNil(msg.method) // response, not a request
        XCTAssertEqual(msg.header("Call-ID"), "8C9D91D6-66D7-42D2-937F-EEB592B1BEFF")
        XCTAssertEqual(msg.header("CSeq"), "3 INVITE")
        XCTAssertEqual(msg.header("Content-Type"), "application/sdp")
        XCTAssertTrue(msg.body.contains("m=audio 15502"))
    }

    func testParseRequestMessage() {
        let raw = "INVITE sip:78088@185.177.2.115 SIP/2.0\r\nVia: SIP/2.0/UDP 185.177.2.115:5060;branch=z9hG4bKabc123\r\nFrom: <sip:73302@185.177.2.115>;tag=remote1\r\nTo: <sip:78088@185.177.2.115>\r\nCall-ID: CALL-ID-12345\r\nCSeq: 1 INVITE\r\nContact: <sip:73302@185.177.2.115>\r\n\r\nv=0\r\no=- 0 0 IN IP4 185.177.2.115\r\nc=IN IP4 185.177.2.115\r\nm=audio 18000 RTP/AVP 8 0 101"

        guard let msg = SipMessage.parse(raw) else {
            XCTFail("Failed to parse request message")
            return
        }

        XCTAssertEqual(msg.method, "INVITE")
        XCTAssertNil(msg.statusCode) // method returns uppercase first word, which is not a valid integer
        XCTAssertEqual(msg.header("Call-ID"), "CALL-ID-12345")
        XCTAssertEqual(msg.header("Contact"), "<sip:73302@185.177.2.115>")
    }

    func testParseEmptyBodyMessage() {
        let raw = "SIP/2.0 401 Unauthorized\r\nVia: SIP/2.0/UDP 0.0.0.0:5060;branch=z9hG4bKxyz\r\nFrom: <sip:78088@185.177.2.115>;tag=abc\r\nTo: <sip:78088@185.177.2.115>;tag=def\r\nCall-ID: REG-123\r\nCSeq: 1 REGISTER\r\nWWW-Authenticate: Digest realm=\"asterisk\", nonce=\"abc123\"\r\n\r\n"

        guard let msg = SipMessage.parse(raw) else {
            XCTFail("Failed to parse 401 message")
            return
        }

        XCTAssertEqual(msg.statusCode, 401)
        XCTAssertTrue(msg.body.isEmpty || msg.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNotNil(msg.header("WWW-Authenticate"))
        XCTAssertTrue(msg.header("WWW-Authenticate")!.contains("Digest"))
    }

    func testParseCaseInsensitiveHeaders() {
        let raw = "SIP/2.0 180 Ringing\r\ncall-id: lowercase-call-id\r\ncseq: 2 INVITE\r\nfrom: <sip:78088@185.177.2.115>;tag=a\r\n\r\n"

        guard let msg = SipMessage.parse(raw) else {
            XCTFail("Failed to parse message with lowercase headers")
            return
        }

        // header() does case-insensitive lookup
        XCTAssertEqual(msg.header("Call-ID"), "lowercase-call-id")
        XCTAssertEqual(msg.header("CSeq"), "2 INVITE")
    }

    func testParseReturnsNilForEmptyInput() {
        XCTAssertNil(SipMessage.parse(""))
    }
}
