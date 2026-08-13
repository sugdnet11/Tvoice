package tj.tvoice.app

internal data class RtpPacketInfo(
    val payloadType: Int,
    val ssrc: Long,
    val payloadOffset: Int,
    val payloadSize: Int,
    val videoOrientationDegrees: Int? = null
)

/** Strict, allocation-light validation for the RTP subset accepted by Tvoice. */
internal object RtpPacketInspector {
    fun inspect(packet: ByteArray, length: Int, videoOrientationExtensionId: Int? = null): RtpPacketInfo? {
        if (length !in 12..packet.size) return null
        if ((packet[0].toInt() ushr 6) and 0x03 != 2) return null
        val csrcCount = packet[0].toInt() and 0x0f
        var offset = 12 + csrcCount * 4
        var videoOrientationDegrees: Int? = null
        if (offset > length) return null
        if (packet[0].toInt() and 0x10 != 0) {
            if (length < offset + 4) return null
            val profile = ((packet[offset].toInt() and 0xff) shl 8) or (packet[offset + 1].toInt() and 0xff)
            val words = ((packet[offset + 2].toInt() and 0xff) shl 8) or
                (packet[offset + 3].toInt() and 0xff)
            val extensionStart = offset + 4
            val extensionEnd = extensionStart + words * 4
            if (extensionEnd > length) return null
            if (profile == 0xBEDE && videoOrientationExtensionId in 1..14) {
                var cursor = extensionStart
                while (cursor < extensionEnd) {
                    val header = packet[cursor].toInt() and 0xff
                    cursor += 1
                    if (header == 0) continue
                    val id = header ushr 4
                    if (id == 15) break
                    val size = (header and 0x0f) + 1
                    if (cursor + size > extensionEnd) return null
                    if (id == videoOrientationExtensionId && size >= 1) {
                        videoOrientationDegrees = (packet[cursor].toInt() and 0x03) * 90
                    }
                    cursor += size
                }
            }
            offset += 4 + words * 4
            if (offset > length) return null
        }
        val hasPadding = packet[0].toInt() and 0x20 != 0
        val paddingSize = if (hasPadding) packet[length - 1].toInt() and 0xff else 0
        if (hasPadding && paddingSize == 0) return null
        if (paddingSize > length - offset) return null
        val payloadSize = length - offset - paddingSize
        if (payloadSize !in 1..1_600) return null
        val ssrc = ((packet[8].toLong() and 0xff) shl 24) or
            ((packet[9].toLong() and 0xff) shl 16) or
            ((packet[10].toLong() and 0xff) shl 8) or
            (packet[11].toLong() and 0xff)
        return RtpPacketInfo(packet[1].toInt() and 0x7f, ssrc, offset, payloadSize, videoOrientationDegrees)
    }
}
