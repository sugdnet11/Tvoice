import XCTest
@testable import TvoiceIOS

final class RtpCodecTests: XCTestCase {

    // MARK: - A-law (PCMA) Round-trip Tests

    func testAlawRoundtripZero() {
        let encoded = RtpCodecs.linearToAlaw(0)
        let decoded = RtpCodecs.alawToLinear(encoded)
        // G.711 is lossy — allow tolerance of 16 (4-bit quantization at low levels)
        XCTAssertTrue(abs(Int32(decoded)) <= 16, "Zero round-trip failed: decoded=\(decoded)")
    }

    func testAlawRoundtripPositive() {
        let values: [Int16] = [100, 1000, 5000, 10000, 20000, 30000]
        for original in values {
            let encoded = RtpCodecs.linearToAlaw(original)
            let decoded = RtpCodecs.alawToLinear(encoded)
            let error = abs(Int32(original) - Int32(decoded))
            // Allow up to 10% error for lossy codec
            let maxError = max(Int32(abs(original)) / 10, 64)
            XCTAssertTrue(error <= maxError, "A-law round-trip failed for \(original): decoded=\(decoded), error=\(error), maxError=\(maxError)")
        }
    }

    func testAlawRoundtripNegative() {
        let values: [Int16] = [-100, -1000, -5000, -10000, -20000, -30000]
        for original in values {
            let encoded = RtpCodecs.linearToAlaw(original)
            let decoded = RtpCodecs.alawToLinear(encoded)
            let error = abs(Int32(original) - Int32(decoded))
            let maxError = max(Int32(abs(original)) / 10, 64)
            XCTAssertTrue(error <= maxError, "A-law round-trip failed for \(original): decoded=\(decoded), error=\(error), maxError=\(maxError)")
        }
    }

    // MARK: - μ-law (PCMU) Round-trip Tests

    func testMulawRoundtripZero() {
        let encoded = RtpCodecs.linearToMulaw(0)
        let decoded = RtpCodecs.mulawToLinear(encoded)
        XCTAssertTrue(abs(Int32(decoded)) <= 16, "Zero round-trip failed: decoded=\(decoded)")
    }

    func testMulawRoundtripPositive() {
        let values: [Int16] = [100, 1000, 5000, 10000, 20000, 30000]
        for original in values {
            let encoded = RtpCodecs.linearToMulaw(original)
            let decoded = RtpCodecs.mulawToLinear(encoded)
            let error = abs(Int32(original) - Int32(decoded))
            let maxError = max(Int32(abs(original)) / 10, 64)
            XCTAssertTrue(error <= maxError, "μ-law round-trip failed for \(original): decoded=\(decoded), error=\(error), maxError=\(maxError)")
        }
    }

    func testMulawRoundtripNegative() {
        let values: [Int16] = [-100, -1000, -5000, -10000, -20000, -30000]
        for original in values {
            let encoded = RtpCodecs.linearToMulaw(original)
            let decoded = RtpCodecs.mulawToLinear(encoded)
            let error = abs(Int32(original) - Int32(decoded))
            let maxError = max(Int32(abs(original)) / 10, 64)
            XCTAssertTrue(error <= maxError, "μ-law round-trip failed for \(original): decoded=\(decoded), error=\(error), maxError=\(maxError)")
        }
    }

    // MARK: - Encoding Determinism

    func testAlawEncodingDeterministic() {
        let sample: Int16 = 12345
        let encoded1 = RtpCodecs.linearToAlaw(sample)
        let encoded2 = RtpCodecs.linearToAlaw(sample)
        XCTAssertEqual(encoded1, encoded2, "A-law encoding should be deterministic")
    }

    func testMulawEncodingDeterministic() {
        let sample: Int16 = 12345
        let encoded1 = RtpCodecs.linearToMulaw(sample)
        let encoded2 = RtpCodecs.linearToMulaw(sample)
        XCTAssertEqual(encoded1, encoded2, "μ-law encoding should be deterministic")
    }

    // MARK: - Symmetry: sign bit

    func testAlawSignSymmetry() {
        let positive: Int16 = 8000
        let negative: Int16 = -8000
        let encodedP = RtpCodecs.linearToAlaw(positive)
        let encodedN = RtpCodecs.linearToAlaw(negative)
        // sign bit is MSB in A-law
        XCTAssertNotEqual(encodedP, encodedN, "Positive and negative should encode differently")
    }

    func testMulawSignSymmetry() {
        let positive: Int16 = 8000
        let negative: Int16 = -8000
        let encodedP = RtpCodecs.linearToMulaw(positive)
        let encodedN = RtpCodecs.linearToMulaw(negative)
        XCTAssertNotEqual(encodedP, encodedN, "Positive and negative should encode differently")
    }

    // MARK: - Edge Values

    func testAlawClipping() {
        // Int16.max should not crash
        let encoded = RtpCodecs.linearToAlaw(Int16.max)
        let decoded = RtpCodecs.alawToLinear(encoded)
        XCTAssertTrue(decoded > 0, "Max positive should decode to positive value")
    }

    func testMulawClipping() {
        let encoded = RtpCodecs.linearToMulaw(Int16.max)
        let decoded = RtpCodecs.mulawToLinear(encoded)
        XCTAssertTrue(decoded > 0, "Max positive should decode to positive value")
    }

    func testMinimumPcmValueDoesNotOverflow() {
        _ = RtpCodecs.linearToAlaw(Int16.min)
        _ = RtpCodecs.linearToMulaw(Int16.min)
    }
}
