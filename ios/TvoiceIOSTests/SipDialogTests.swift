import XCTest
@testable import TvoiceIOS

final class SipDialogTests: XCTestCase {

    func testOutgoingDialogCreation() {
        let dialog = SipDialog(direction: .outgoing, peerNumber: "73302")

        XCTAssertEqual(dialog.direction, .outgoing)
        XCTAssertEqual(dialog.peerNumber, "73302")
        XCTAssertFalse(dialog.callID.isEmpty)
        XCTAssertFalse(dialog.localTag.isEmpty)
        XCTAssertNil(dialog.remoteTag)
        XCTAssertEqual(dialog.localCSeq, 1)
        XCTAssertEqual(dialog.remoteCSeq, 0)
        XCTAssertTrue(dialog.viaBranch.hasPrefix("z9hG4bK"))
        XCTAssertTrue(dialog.requestURI.contains("73302"))
        XCTAssertFalse(dialog.connected)
        XCTAssertFalse(dialog.accepted)
    }

    func testIncomingDialogCreation() {
        let dialog = SipDialog(direction: .incoming, peerNumber: "78088")

        XCTAssertEqual(dialog.direction, .incoming)
        XCTAssertEqual(dialog.peerNumber, "78088")
        XCTAssertTrue(dialog.requestURI.contains("78088"))
    }

    func testCustomCallIDAndTag() {
        let dialog = SipDialog(
            direction: .outgoing,
            peerNumber: "12345",
            callID: "custom-call-id",
            localTag: "custom-tag"
        )

        XCTAssertEqual(dialog.callID, "custom-call-id")
        XCTAssertEqual(dialog.localTag, "custom-tag")
    }

    func testDialogStateChanges() {
        let dialog = SipDialog(direction: .outgoing, peerNumber: "73302")

        dialog.remoteTag = "remote-tag-abc"
        dialog.connected = true
        dialog.accepted = true
        dialog.localCSeq = 5
        dialog.remoteCSeq = 3

        XCTAssertEqual(dialog.remoteTag, "remote-tag-abc")
        XCTAssertTrue(dialog.connected)
        XCTAssertTrue(dialog.accepted)
        XCTAssertEqual(dialog.localCSeq, 5)
        XCTAssertEqual(dialog.remoteCSeq, 3)
    }

    func testUniqueDialogIds() {
        let dialog1 = SipDialog(direction: .outgoing, peerNumber: "100")
        let dialog2 = SipDialog(direction: .outgoing, peerNumber: "100")

        XCTAssertNotEqual(dialog1.callID, dialog2.callID, "Each dialog should have a unique Call-ID")
        XCTAssertNotEqual(dialog1.localTag, dialog2.localTag, "Each dialog should have a unique local tag")
    }
}
