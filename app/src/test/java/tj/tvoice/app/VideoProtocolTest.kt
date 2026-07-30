package tj.tvoice.app

import java.net.InetAddress
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class VideoProtocolTest {
    @Test
    fun parsesH264VideoSectionAndMediaAddress() {
        val media = RemoteVideoMedia.fromSdp(
            """v=0
                |c=IN IP4 192.0.2.10
                |m=audio 10000 RTP/AVP 8
                |m=video 12000 RTP/AVP 99
                |c=IN IP4 198.51.100.20
                |a=rtpmap:99 H264/90000
                |a=extmap:4 urn:3gpp:video-orientation
                |a=fmtp:99 packetization-mode=1;profile-level-id=42e01f;sprop-parameter-sets=ZwEC,aAM=
            """.trimMargin(),
            InetAddress.getByName("127.0.0.1")
        )
        assertNotNull(media)
        assertEquals("198.51.100.20", media?.address?.hostAddress)
        assertEquals(12000, media?.port)
        assertEquals(99, media?.payloadType)
        assertEquals(true, media?.sendsVideo)
        assertEquals(true, media?.receivesVideo)
        assertEquals(2, media?.parameterSets?.size)
        assertEquals(4, media?.videoOrientationExtensionId)
    }

    @Test
    fun fragmentsAndReassemblesFuA() {
        val nal = ByteArray(3_000) { (it and 0xff).toByte() }.also { it[0] = 0x65 }
        val fragments = H264RtpPacketizer.fragment(nal, 900)
        assertEquals(4, fragments.size)
        assertEquals(0x80, fragments.first().payload[1].toInt() and 0x80)
        assertEquals(0x40, fragments.last().payload[1].toInt() and 0x40)
        val restored = byteArrayOf(
            ((fragments[0].payload[0].toInt() and 0xe0) or
                (fragments[0].payload[1].toInt() and 0x1f)).toByte()
        ) + fragments.flatMap { it.payload.drop(2) }.toByteArray()
        assertArrayEquals(nal, restored)
    }

    @Test
    fun splitsAnnexBAccessUnit() {
        val accessUnit = byteArrayOf(0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x65, 3, 4)
        val units = H264RtpPacketizer.splitAccessUnit(accessUnit)
        assertEquals(2, units.size)
        assertArrayEquals(byteArrayOf(0x67, 1, 2), units[0])
        assertArrayEquals(byteArrayOf(0x65, 3, 4), units[1])
    }

    @Test
    fun rejectsInterleavedOrModeZeroH264() {
        val media = RemoteVideoMedia.fromSdp(
            """v=0
                |m=video 12000 RTP/AVP 99
                |a=rtpmap:99 H264/90000
                |a=fmtp:99 packetization-mode=0
            """.trimMargin(),
            InetAddress.getByName("127.0.0.1")
        )
        assertEquals(null, media)
    }

    @Test
    fun unpacksStapAParameterSets() {
        val stap = byteArrayOf(0x78, 0, 3, 0x67, 1, 2, 0, 2, 0x68, 3)
        val units = H264RtpPacketizer.unpackStapA(stap)
        assertEquals(2, units.size)
        assertArrayEquals(byteArrayOf(0x67, 1, 2), units[0])
        assertArrayEquals(byteArrayOf(0x68, 3), units[1])
    }

    @Test
    fun splitsAvcDecoderConfigurationRecord() {
        val configuration = byteArrayOf(
            1, 0x42, 0xe0.toByte(), 0x1f, 0xff.toByte(), 0xe1.toByte(),
            0, 3, 0x67, 1, 2,
            1, 0, 2, 0x68, 3
        )
        val units = H264RtpPacketizer.splitAccessUnit(configuration)
        assertEquals(2, units.size)
        assertArrayEquals(byteArrayOf(0x67, 1, 2), units[0])
        assertArrayEquals(byteArrayOf(0x68, 3), units[1])
    }
}
