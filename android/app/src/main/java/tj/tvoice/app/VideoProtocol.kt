package tj.tvoice.app

import java.net.InetAddress
import java.util.Base64

internal data class RemoteVideoMedia(
    val address: InetAddress,
    val port: Int,
    val payloadType: Int,
    val sendsVideo: Boolean,
    val receivesVideo: Boolean,
    val parameterSets: List<ByteArray>,
    val videoOrientationExtensionId: Int? = null
) {
    companion object {
        fun fromSdp(sdp: String, fallbackAddress: InetAddress): RemoteVideoMedia? {
            var sessionAddress: InetAddress? = null
            var videoAddress: InetAddress? = null
            var videoPort: Int? = null
            var videoPayloads = emptyList<Int>()
            var transportSupported = false
            var inVideoSection = false
            var mediaSectionStarted = false
            var direction = "sendrecv"
            val codecs = mutableMapOf<Int, String>()
            val formatParameters = mutableMapOf<Int, String>()
            var videoOrientationExtensionId: Int? = null

            sdp.lineSequence().map { it.trim() }.forEach { line ->
                when {
                    line.startsWith("m=", ignoreCase = true) -> {
                        mediaSectionStarted = true
                        inVideoSection = line.startsWith("m=video ", ignoreCase = true)
                        if (inVideoSection) {
                            direction = "sendrecv"
                            val fields = line.split(Regex("\\s+"))
                            videoPort = fields.getOrNull(1)?.substringBefore('/')?.toIntOrNull()
                            transportSupported = fields.getOrNull(2)?.uppercase() in setOf("RTP/AVP", "RTP/AVPF")
                            videoPayloads = fields.drop(3).mapNotNull { it.toIntOrNull() }
                        }
                    }
                    line.startsWith("c=IN IP4 ", true) || line.startsWith("c=IN IP6 ", true) -> {
                        val resolved = line.substringAfterLast(' ').trim()
                            .let { runCatching { InetAddress.getByName(it) }.getOrNull() }
                        if (inVideoSection) videoAddress = resolved
                        else if (!mediaSectionStarted) sessionAddress = resolved
                    }
                    inVideoSection && line.startsWith("a=rtpmap:", true) -> {
                        val payload = line.substringAfter(':').substringBefore(' ').toIntOrNull()
                        val codec = line.substringAfter(' ', "").substringBefore('/').uppercase()
                        if (payload != null && codec.isNotBlank()) codecs[payload] = codec
                    }
                    inVideoSection && line.startsWith("a=fmtp:", true) -> {
                        val payload = line.substringAfter(':').substringBefore(' ').toIntOrNull()
                        if (payload != null) formatParameters[payload] = line.substringAfter(' ', "")
                    }
                    inVideoSection && line.startsWith("a=extmap:", true) &&
                        line.contains("urn:3gpp:video-orientation", true) -> {
                        videoOrientationExtensionId = line.substringAfter(':')
                            .substringBefore(' ')
                            .substringBefore('/')
                            .toIntOrNull()
                            ?.takeIf { it in 1..14 }
                    }
                    inVideoSection && line.equals("a=sendonly", true) -> direction = "sendonly"
                    inVideoSection && line.equals("a=recvonly", true) -> direction = "recvonly"
                    inVideoSection && line.equals("a=inactive", true) -> direction = "inactive"
                    inVideoSection && line.equals("a=sendrecv", true) -> direction = "sendrecv"
                }
            }

            if (!transportSupported) return null
            val port = videoPort?.takeIf { it in 1..65535 } ?: return null
            val payload = videoPayloads.firstOrNull { candidate ->
                candidate in 0..127 && codecs[candidate] == "H264" &&
                    (formatParameters[candidate]?.let(::supportsPacketizationMode) != false)
            } ?: return null
            return RemoteVideoMedia(
                videoAddress ?: sessionAddress ?: fallbackAddress,
                port,
                payload,
                sendsVideo = direction == "sendrecv" || direction == "sendonly",
                receivesVideo = direction == "sendrecv" || direction == "recvonly",
                parameterSets = parseParameterSets(formatParameters[payload].orEmpty()),
                videoOrientationExtensionId = videoOrientationExtensionId
            )
        }

        private fun supportsPacketizationMode(parameters: String): Boolean {
            val mode = parameters.split(';')
                .map { it.trim() }
                .firstOrNull { it.startsWith("packetization-mode=", true) }
                ?.substringAfter('=')
                ?.toIntOrNull()
            return mode == null || mode == 1
        }

        private fun parseParameterSets(parameters: String): List<ByteArray> {
            val encoded = parameters.split(';')
                .map { it.trim() }
                .firstOrNull { it.startsWith("sprop-parameter-sets=", true) }
                ?.substringAfter('=')
                ?: return emptyList()
            return encoded.split(',').take(4).mapNotNull { value ->
                runCatching { Base64.getDecoder().decode(value.trim()) }
                    .getOrNull()
                    ?.takeIf { it.size in 1..4_096 }
            }
        }
    }
}

internal data class H264RtpFragment(val payload: ByteArray, val marker: Boolean)

/** RFC 6184 non-interleaved packetization used by Asterisk H.264 pass-through. */
internal object H264RtpPacketizer {
    fun splitAccessUnit(data: ByteArray): List<ByteArray> {
        val annexB = splitAnnexB(data)
        if (annexB.isNotEmpty()) return annexB
        val configuration = splitAvcConfiguration(data)
        if (configuration.isNotEmpty()) return configuration
        val avcc = splitAvcc(data)
        if (avcc.isNotEmpty()) return avcc
        return listOf(data).filter(ByteArray::isNotEmpty)
    }

    fun fragment(nal: ByteArray, maxPayloadSize: Int = 1_200): List<H264RtpFragment> {
        require(maxPayloadSize >= 4) { "Слишком маленький RTP payload" }
        if (nal.isEmpty()) return emptyList()
        if (nal.size <= maxPayloadSize) return listOf(H264RtpFragment(nal.copyOf(), true))

        val indicator = (nal[0].toInt() and 0xe0) or 28
        val type = nal[0].toInt() and 0x1f
        val chunkSize = maxPayloadSize - 2
        val result = mutableListOf<H264RtpFragment>()
        var offset = 1
        while (offset < nal.size) {
            val count = minOf(chunkSize, nal.size - offset)
            val start = offset == 1
            val end = offset + count == nal.size
            val payload = ByteArray(count + 2)
            payload[0] = indicator.toByte()
            payload[1] = (type or (if (start) 0x80 else 0) or (if (end) 0x40 else 0)).toByte()
            nal.copyInto(payload, 2, offset, offset + count)
            result += H264RtpFragment(payload, end)
            offset += count
        }
        return result
    }

    fun unpackStapA(payload: ByteArray): List<ByteArray> {
        if (payload.isEmpty() || payload[0].toInt() and 0x1f != 24) return emptyList()
        val units = mutableListOf<ByteArray>()
        var offset = 1
        while (offset + 2 <= payload.size) {
            val size = ((payload[offset].toInt() and 0xff) shl 8) or
                (payload[offset + 1].toInt() and 0xff)
            offset += 2
            if (size <= 0 || offset + size > payload.size) return emptyList()
            units += payload.copyOfRange(offset, offset + size)
            offset += size
        }
        return units.takeIf { offset == payload.size }.orEmpty()
    }

    private fun splitAnnexB(data: ByteArray): List<ByteArray> {
        val starts = mutableListOf<Pair<Int, Int>>()
        var index = 0
        while (index + 3 <= data.size) {
            val prefix = when {
                index + 4 <= data.size && data[index] == 0.toByte() && data[index + 1] == 0.toByte() &&
                    data[index + 2] == 0.toByte() && data[index + 3] == 1.toByte() -> 4
                data[index] == 0.toByte() && data[index + 1] == 0.toByte() && data[index + 2] == 1.toByte() -> 3
                else -> 0
            }
            if (prefix > 0) {
                starts += index to prefix
                index += prefix
            } else index += 1
        }
        if (starts.isEmpty()) return emptyList()
        return starts.mapIndexedNotNull { position, (start, prefix) ->
            val from = start + prefix
            val to = starts.getOrNull(position + 1)?.first ?: data.size
            data.copyOfRange(from, to).takeIf(ByteArray::isNotEmpty)
        }
    }

    private fun splitAvcc(data: ByteArray): List<ByteArray> {
        val result = mutableListOf<ByteArray>()
        var offset = 0
        while (offset + 4 <= data.size) {
            val size = ((data[offset].toInt() and 0xff) shl 24) or
                ((data[offset + 1].toInt() and 0xff) shl 16) or
                ((data[offset + 2].toInt() and 0xff) shl 8) or
                (data[offset + 3].toInt() and 0xff)
            if (size <= 0 || offset + 4 + size > data.size) return emptyList()
            result += data.copyOfRange(offset + 4, offset + 4 + size)
            offset += 4 + size
        }
        return result.takeIf { offset == data.size }.orEmpty()
    }

    private fun splitAvcConfiguration(data: ByteArray): List<ByteArray> {
        if (data.size < 7 || data[0] != 1.toByte()) return emptyList()
        val units = mutableListOf<ByteArray>()
        var offset = 6
        val spsCount = data[5].toInt() and 0x1f
        repeat(spsCount) {
            if (offset + 2 > data.size) return emptyList()
            val size = ((data[offset].toInt() and 0xff) shl 8) or (data[offset + 1].toInt() and 0xff)
            offset += 2
            if (size <= 0 || offset + size > data.size) return emptyList()
            units += data.copyOfRange(offset, offset + size)
            offset += size
        }
        if (offset >= data.size) return emptyList()
        val ppsCount = data[offset].toInt() and 0xff
        offset += 1
        repeat(ppsCount) {
            if (offset + 2 > data.size) return emptyList()
            val size = ((data[offset].toInt() and 0xff) shl 8) or (data[offset + 1].toInt() and 0xff)
            offset += 2
            if (size <= 0 || offset + size > data.size) return emptyList()
            units += data.copyOfRange(offset, offset + size)
            offset += size
        }
        return units.takeIf { it.isNotEmpty() }.orEmpty()
    }
}
