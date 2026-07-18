package tj.tvoice.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TvoiceProtocolTest {
    @Test
    fun parsesSipResponseAndCompactHeaders() {
        val raw = (
            "SIP/2.0 401 Unauthorized\r\n" +
                "v: SIP/2.0/UDP 10.0.0.2:4567;rport\r\n" +
                "f: <sip:73302@example.org>;tag=abc\r\n" +
                "t: <sip:73302@example.org>\r\n" +
                "i: call-1\r\n" +
                "CSeq: 2 REGISTER\r\n" +
                "l: 0\r\n\r\n"
            ).toByteArray()
        val message = SipMessage.parse(raw, raw.size)
        assertNotNull(message)
        assertEquals(401, message?.statusCode)
        assertEquals("call-1", message?.header("Call-ID"))
        assertEquals("REGISTER", message?.cseqMethod())
        assertEquals("abc", headerTag(message?.header("From")))
    }

    @Test
    fun createsKnownDigestResponse() {
        val challenge = DigestChallenge(
            realm = "testrealm@host.com",
            nonce = "dcd98b7102dd2f0e8b11d0f600bfb0c093",
            qop = "auth",
            opaque = "5ccc069c403ebaf9f0171e9517f40e41",
            algorithm = "MD5"
        )
        val header = DigestAuth.create(
            challenge = challenge,
            username = "Mufasa",
            password = "Circle Of Life",
            method = "GET",
            uri = "/dir/index.html",
            nonceCount = 1,
            cnonceOverride = "0a4f113b"
        )
        assertTrue(header.contains("response=\"6629fae49393a05397450978507c4ef1\""))
    }

    @Test
    fun g711RoundTripsSpeechSamples() {
        val samples = listOf<Short>(-16000, -4000, -100, 0, 100, 4000, 16000)
        samples.forEach { sample ->
            val alaw = G711.decodeAlaw(G711.encodeAlaw(sample)).toInt()
            val ulaw = G711.decodeUlaw(G711.encodeUlaw(sample)).toInt()
            assertTrue("A-law $sample -> $alaw", kotlin.math.abs(alaw - sample) < 1200)
            assertTrue("mu-law $sample -> $ulaw", kotlin.math.abs(ulaw - sample) < 1200)
        }
    }

    @Test
    fun readsPublicUdpMappingFromVia() {
        val mapping = ViaMapping.parse(
            "SIP/2.0/UDP 192.168.1.20:49152;branch=z9hG4bK-test;received=203.0.113.17;rport=62001"
        )
        assertEquals(ViaMapping("203.0.113.17", 62001), mapping)
    }
}
