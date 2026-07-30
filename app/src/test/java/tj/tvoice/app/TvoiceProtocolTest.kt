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

    @Test
    fun authenticationChallengeDoesNotEstablishDialog() {
        assertTrue(responseEstablishesDialog(180))
        assertTrue(responseEstablishesDialog(200))
        assertTrue(!responseEstablishesDialog(401))
        assertTrue(!responseEstablishesDialog(407))
        assertTrue(!responseEstablishesDialog(481))
    }

    @Test
    fun ignoresLateProvisionalResponsesAfterCallConnects() {
        assertEquals(CallState.OutgoingProgress, provisionalCallState(183, connected = false))
        assertEquals(CallState.OutgoingRinging, provisionalCallState(180, connected = false))
        assertEquals(null, provisionalCallState(180, connected = true))
        assertEquals(null, provisionalCallState(183, connected = true))
    }

    @Test
    fun parsesSipMessageBody() {
        val raw = (
            "MESSAGE sip:73302@example.org SIP/2.0\r\n" +
                "From: <sip:70007@example.org>;tag=chat1\r\n" +
                "To: <sip:73302@example.org>\r\n" +
                "Call-ID: message-1\r\n" +
                "CSeq: 1 MESSAGE\r\n" +
                "Content-Type: text/plain; charset=UTF-8\r\n" +
                "Content-Length: 24\r\n\r\n" +
                "Привет из Tvoice"
            ).toByteArray(Charsets.UTF_8)
        val message = SipMessage.parse(raw, raw.size)
        assertNotNull(message)
        assertEquals("MESSAGE", message?.method)
        assertEquals("MESSAGE", message?.cseqMethod())
        assertEquals("Привет из Tvoice", message?.body)
    }

    @Test
    fun validatesRtpHeaderAndRejectsMalformedExtension() {
        val packet = byteArrayOf(
            0x80.toByte(), 0x08, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
            0x12, 0x34, 0x56, 0x78,
            0x55, 0x55
        )
        val info = RtpPacketInspector.inspect(packet, packet.size)
        assertNotNull(info)
        assertEquals(8, info?.payloadType)
        assertEquals(0x12345678L, info?.ssrc)
        assertEquals(12, info?.payloadOffset)
        assertEquals(2, info?.payloadSize)

        val malformed = packet.copyOf().also { it[0] = 0x90.toByte() }
        assertEquals(null, RtpPacketInspector.inspect(malformed, malformed.size))
    }

    @Test
    fun rejectsMalformedSipAndHonorsContentLength() {
        val malformed = "NOT SIP\r\nCall-ID: x\r\n\r\n".toByteArray()
        assertEquals(null, SipMessage.parse(malformed, malformed.size))

        val raw = (
            "MESSAGE sip:70001@example.org SIP/2.0\r\n" +
                "Call-ID: safe\r\nCSeq: 1 MESSAGE\r\nContent-Length: 5\r\n\r\nhelloignored"
            ).toByteArray()
        assertEquals("hello", SipMessage.parse(raw, raw.size)?.body)
    }

    @Test
    fun rejectsSipMessageSmugglingAndInvalidUtf8() {
        val conflictingLength = (
            "MESSAGE sip:70001@example.org SIP/2.0\r\n" +
                "Call-ID: safe\r\nCSeq: 1 MESSAGE\r\n" +
                "Content-Length: 5\r\nl: 7\r\n\r\nhello!!"
            ).toByteArray()
        assertEquals(null, SipMessage.parse(conflictingLength, conflictingLength.size))

        val invalidUtf8 = "MESSAGE sip:70001@example.org SIP/2.0\r\nX: ".toByteArray() +
            byteArrayOf(0xc3.toByte(), 0x28) + "\r\n\r\n".toByteArray()
        assertEquals(null, SipMessage.parse(invalidUtf8, invalidUtf8.size))
    }

    @Test
    fun validatesRtpPadding() {
        val valid = byteArrayOf(
            0xa0.toByte(), 0x08, 0, 1, 0, 0, 0, 1, 1, 2, 3, 4,
            0x55, 0x00, 0x02
        )
        assertEquals(1, RtpPacketInspector.inspect(valid, valid.size)?.payloadSize)

        val zeroPadding = valid.copyOf().also { it[it.lastIndex] = 0 }
        assertEquals(null, RtpPacketInspector.inspect(zeroPadding, zeroPadding.size))
    }

    @Test
    fun keepsAudioAndVideoMediaAddressesSeparate() {
        val media = RemoteMedia.fromSdp(
            """v=0
                |c=IN IP4 192.0.2.1
                |m=audio 10000 RTP/AVP 8
                |c=IN IP4 198.51.100.10
                |a=rtpmap:8 PCMA/8000
                |m=video 12000 RTP/AVP 96
                |c=IN IP4 203.0.113.20
                |a=rtpmap:96 H264/90000
            """.trimMargin(),
            java.net.InetAddress.getByName("127.0.0.1")
        )
        assertEquals("198.51.100.10", media?.address?.hostAddress)
        assertEquals(10000, media?.port)
    }

    @Test
    fun videoDirectionDoesNotPutAudioOnHold() {
        val sdp = """v=0
            |m=audio 10000 RTP/AVP 8
            |a=sendrecv
            |m=video 12000 RTP/AVP 96
            |a=inactive
        """.trimMargin()
        assertEquals("sendrecv", SdpMediaDirection.of(sdp, "audio"))
        assertEquals("inactive", SdpMediaDirection.of(sdp, "video"))
    }

    @Test
    fun readsRtpCvoRotationFromOneByteHeaderExtension() {
        val packet = byteArrayOf(
            0x90.toByte(), 96, 0, 1,
            0, 0, 0, 1,
            0, 0, 0, 2,
            0xBE.toByte(), 0xDE.toByte(), 0, 1,
            0x40, 0x01, 0, 0,
            0x65
        )
        val info = RtpPacketInspector.inspect(packet, packet.size, 4)
        assertEquals(20, info?.payloadOffset)
        assertEquals(90, info?.videoOrientationDegrees)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsDigestHeaderInjection() {
        DigestAuth.create(
            DigestChallenge("realm", "nonce", null, null, "MD5"),
            "user\r\nInjected: true",
            "password",
            "REGISTER",
            "sip:example.org",
            1
        )
    }
}
