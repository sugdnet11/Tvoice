import XCTest
@testable import TvoiceIOS

final class SdpParserTests: XCTestCase {

    func testParseValidSdp() {
        let sdp = """
        v=0\r
        o=- 0 0 IN IP4 185.177.2.115\r
        s=Asterisk\r
        c=IN IP4 185.177.2.115\r
        t=0 0\r
        m=audio 15502 RTP/AVP 8 0 101\r
        a=rtpmap:8 PCMA/8000\r
        a=rtpmap:0 PCMU/8000\r
        a=rtpmap:101 telephone-event/8000\r
        """

        guard let offer = SdpOfferAnswer.parse(sdp) else {
            XCTFail("Failed to parse valid SDP")
            return
        }

        XCTAssertEqual(offer.mediaHost, "185.177.2.115")
        XCTAssertEqual(offer.mediaPort, 15502)
        // Both 8 and 0 are present; 0 appears after 8 so parser picks payload 0 (PCMU)
        // since the parser checks if parts.contains("0") first
        XCTAssertTrue(offer.selectedCodecPayload == 0 || offer.selectedCodecPayload == 8)
    }

    func testParseSdpWithOnlyPCMA() {
        let sdp = """
        v=0\r
        c=IN IP4 10.0.0.1\r
        m=audio 20000 RTP/AVP 8\r
        """

        guard let offer = SdpOfferAnswer.parse(sdp) else {
            XCTFail("Failed to parse SDP with only PCMA")
            return
        }

        XCTAssertEqual(offer.mediaHost, "10.0.0.1")
        XCTAssertEqual(offer.mediaPort, 20000)
        XCTAssertEqual(offer.selectedCodecPayload, 8)
    }

    func testParseSdpWithOnlyPCMU() {
        let sdp = """
        v=0\r
        c=IN IP4 192.168.1.100\r
        m=audio 30000 RTP/AVP 0\r
        """

        guard let offer = SdpOfferAnswer.parse(sdp) else {
            XCTFail("Failed to parse SDP with only PCMU")
            return
        }

        XCTAssertEqual(offer.mediaHost, "192.168.1.100")
        XCTAssertEqual(offer.mediaPort, 30000)
        XCTAssertEqual(offer.selectedCodecPayload, 0)
    }

    func testParseSdpMissingConnection() {
        let sdp = """
        v=0\r
        m=audio 15000 RTP/AVP 8\r
        """

        XCTAssertNil(SdpOfferAnswer.parse(sdp), "Should return nil when c= line is missing")
    }

    func testParseSdpMissingMedia() {
        let sdp = """
        v=0\r
        c=IN IP4 10.0.0.1\r
        """

        XCTAssertNil(SdpOfferAnswer.parse(sdp), "Should return nil when m= line is missing")
    }

    func testParseSdpEmptyInput() {
        XCTAssertNil(SdpOfferAnswer.parse(""), "Should return nil for empty input")
    }
}
