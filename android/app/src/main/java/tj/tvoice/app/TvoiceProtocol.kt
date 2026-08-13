package tj.tvoice.app

import java.security.MessageDigest
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Locale
import java.util.concurrent.ThreadLocalRandom

enum class RegistrationState {
    None, Progress, Ok, Failed, Cleared
}

enum class CallState {
    Idle,
    IncomingReceived,
    OutgoingInit,
    OutgoingProgress,
    OutgoingRinging,
    Connected,
    StreamsRunning,
    Paused,
    End,
    Error,
    Released
}

enum class MessageState {
    Sending, Sent, Received, Error
}

internal fun provisionalCallState(status: Int, connected: Boolean): CallState? {
    if (connected) return null
    return when (status) {
        100, 183 -> CallState.OutgoingProgress
        180 -> CallState.OutgoingRinging
        else -> null
    }
}

internal data class SipMessage(
    val startLine: String,
    val headers: Map<String, List<String>>,
    val body: String
) {
    val statusCode: Int?
        get() = if (startLine.startsWith("SIP/2.0")) {
            startLine.split(' ').getOrNull(1)?.toIntOrNull()
        } else null

    val method: String?
        get() = if (!startLine.startsWith("SIP/2.0")) startLine.substringBefore(' ').uppercase(Locale.US) else null

    fun header(name: String): String? = headers(name).firstOrNull()
    fun headers(name: String): List<String> {
        val normalized = name.lowercase(Locale.US)
        val compact = when (normalized) {
            "via" -> "v"
            "from" -> "f"
            "to" -> "t"
            "call-id" -> "i"
            "contact" -> "m"
            "content-length" -> "l"
            "content-type" -> "c"
            else -> null
        }
        return headers[normalized] ?: compact?.let(headers::get).orEmpty()
    }
    fun cseqMethod(): String? = header("CSeq")?.substringAfter(' ')?.trim()?.uppercase(Locale.US)
    fun cseqNumber(): Int? = header("CSeq")?.substringBefore(' ')?.trim()?.toIntOrNull()

    companion object {
        fun parse(data: ByteArray, length: Int): SipMessage? {
            if (length !in 1..minOf(data.size, MAX_MESSAGE_BYTES)) return null
            val text = runCatching {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(data, 0, length))
                    .toString()
            }.getOrNull() ?: return null
            val divider = when {
                "\r\n\r\n" in text -> "\r\n\r\n"
                "\n\n" in text -> "\n\n"
                else -> null
            }
            val head = if (divider == null) text else text.substringBefore(divider)
            val body = if (divider == null) "" else text.substringAfter(divider)
            val lines = head.split(Regex("\r?\n"))
            val start = lines.firstOrNull()?.trim().orEmpty()
            if (!isValidStartLine(start) || lines.size > MAX_HEADER_COUNT) return null

            val values = linkedMapOf<String, MutableList<String>>()
            var lastName: String? = null
            for (line in lines.drop(1)) {
                if (line.length > MAX_HEADER_LINE_CHARS || '\u0000' in line) return null
                if ((line.startsWith(' ') || line.startsWith('\t')) && lastName != null) {
                    val list = values[lastName] ?: continue
                    list[list.lastIndex] = list.last() + " " + line.trim()
                    continue
                }
                val colon = line.indexOf(':')
                if (colon <= 0) return null
                val name = line.substring(0, colon).trim().lowercase(Locale.US)
                if (!name.matches(HEADER_NAME)) return null
                val value = line.substring(colon + 1).trim()
                values.getOrPut(name) { mutableListOf() }.add(value)
                lastName = name
            }
            val lengthHeaders = values["content-length"].orEmpty() + values["l"].orEmpty()
            val parsedLengths = lengthHeaders.map { it.toIntOrNull() ?: return null }
            if (parsedLengths.any { it < 0 } || parsedLengths.distinct().size > 1) return null
            val declaredLength = parsedLengths.firstOrNull()
            val normalizedBody = if (declaredLength == null) body else {
                val bytes = body.toByteArray(Charsets.UTF_8)
                if (bytes.size < declaredLength) return null
                bytes.copyOfRange(0, declaredLength).toString(Charsets.UTF_8)
            }
            return SipMessage(start, values, normalizedBody)
        }

        private fun isValidStartLine(value: String): Boolean {
            if (value.length > 1_024 || '\r' in value || '\n' in value) return false
            if (value.startsWith("SIP/2.0 ")) {
                return value.split(' ').getOrNull(1)?.toIntOrNull() in 100..699
            }
            val parts = value.split(' ')
            return parts.size == 3 && parts[0].matches(Regex("[A-Z]+")) &&
                parts[1].startsWith("sip:", ignoreCase = true) && parts[2] == "SIP/2.0"
        }

        private const val MAX_MESSAGE_BYTES = 65_535
        private const val MAX_HEADER_COUNT = 256
        private const val MAX_HEADER_LINE_CHARS = 8_192
        private val HEADER_NAME = Regex("[A-Za-z0-9!#$%&'*+.^_`|~-]+")
    }
}

internal data class DigestChallenge(
    val realm: String,
    val nonce: String,
    val qop: String?,
    val opaque: String?,
    val algorithm: String
) {
    companion object {
        fun parse(value: String): DigestChallenge? {
            val source = value.substringAfter("Digest", value).trim()
            val fields = mutableMapOf<String, String>()
            val pattern = Regex("([A-Za-z0-9_-]+)\\s*=\\s*(?:\"([^\"]*)\"|([^,\\s]+))")
            pattern.findAll(source).forEach { match ->
                fields[match.groupValues[1].lowercase(Locale.US)] =
                    match.groupValues[2].ifEmpty { match.groupValues[3] }
            }
            val realm = fields["realm"] ?: return null
            val nonce = fields["nonce"] ?: return null
            val qop = fields["qop"]?.split(',')?.map { it.trim() }?.firstOrNull { it.equals("auth", true) }
            return DigestChallenge(realm, nonce, qop, fields["opaque"], fields["algorithm"] ?: "MD5")
        }
    }
}

internal object DigestAuth {
    fun create(
        challenge: DigestChallenge,
        username: String,
        password: String,
        method: String,
        uri: String,
        nonceCount: Int,
        cnonceOverride: String? = null
    ): String {
        require(challenge.algorithm.equals("MD5", true)) { "Сервер запросил неподдерживаемый алгоритм ${challenge.algorithm}" }
        require(listOf(username, challenge.realm, challenge.nonce, uri).none { '\r' in it || '\n' in it }) {
            "Недопустимые символы в SIP-аутентификации"
        }
        val nc = nonceCount.toString(16).padStart(8, '0')
        val cnonce = cnonceOverride ?: randomHex(8)
        require(listOf(cnonce, challenge.opaque.orEmpty()).none { '\r' in it || '\n' in it }) {
            "Недопустимые символы в SIP-аутентификации"
        }
        val ha1 = md5("$username:${challenge.realm}:$password")
        val ha2 = md5("$method:$uri")
        val response = if (challenge.qop != null) {
            md5("$ha1:${challenge.nonce}:$nc:$cnonce:${challenge.qop}:$ha2")
        } else {
            md5("$ha1:${challenge.nonce}:$ha2")
        }
        return buildString {
            append("Digest username=\"").append(quoted(username)).append("\"")
            append(", realm=\"").append(quoted(challenge.realm)).append("\"")
            append(", nonce=\"").append(quoted(challenge.nonce)).append("\"")
            append(", uri=\"").append(quoted(uri)).append("\"")
            append(", response=\"").append(response).append("\"")
            append(", algorithm=MD5")
            if (challenge.qop != null) {
                append(", qop=").append(challenge.qop)
                append(", nc=").append(nc)
                append(", cnonce=\"").append(quoted(cnonce)).append("\"")
            }
            challenge.opaque?.let { append(", opaque=\"").append(quoted(it)).append("\"") }
        }
    }

    private fun quoted(value: String): String = value.replace("\\", "\\\\").replace("\"", "\\\"")

    private fun md5(value: String): String = MessageDigest.getInstance("MD5")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

internal object G711 {
    fun encodeAlaw(sample: Short): Byte {
        var pcm = sample.toInt() shr 3
        val mask: Int
        if (pcm >= 0) {
            mask = 0xD5
        } else {
            mask = 0x55
            pcm = -pcm - 1
        }
        if (pcm > 4095) pcm = 4095
        val segment = when {
            pcm > 2047 -> 7
            pcm > 1023 -> 6
            pcm > 511 -> 5
            pcm > 255 -> 4
            pcm > 127 -> 3
            pcm > 63 -> 2
            pcm > 31 -> 1
            else -> 0
        }
        val encoded = if (segment < 2) {
            (segment shl 4) or ((pcm shr 1) and 0x0f)
        } else {
            (segment shl 4) or ((pcm shr segment) and 0x0f)
        }
        return (encoded xor mask).toByte()
    }

    fun decodeAlaw(value: Byte): Short {
        val a = value.toInt() xor 0x55
        var sample = (a and 0x0f) shl 4
        val segment = (a and 0x70) shr 4
        sample += 8
        if (segment >= 1) sample += 0x100
        if (segment > 1) sample = sample shl (segment - 1)
        return if ((a and 0x80) != 0) sample.toShort() else (-sample).toShort()
    }

    fun encodeUlaw(sample: Short): Byte {
        var pcm = sample.toInt()
        val mask: Int
        if (pcm < 0) {
            pcm = -pcm
            mask = 0x7f
        } else {
            mask = 0xff
        }
        pcm = (pcm + 0x84).coerceAtMost(32635)
        var exponent = 7
        var expMask = 0x4000
        while (exponent > 0 && pcm and expMask == 0) {
            exponent--
            expMask = expMask shr 1
        }
        val mantissa = (pcm shr (exponent + 3)) and 0x0f
        return (((exponent shl 4) or mantissa) xor mask).toByte()
    }

    fun decodeUlaw(value: Byte): Short {
        val u = value.toInt().inv() and 0xff
        val sign = u and 0x80
        val exponent = (u shr 4) and 0x07
        val mantissa = u and 0x0f
        var sample = ((mantissa shl 3) + 0x84) shl exponent
        sample -= 0x84
        return if (sign != 0) (-sample).toShort() else sample.toShort()
    }
}

internal fun randomHex(bytes: Int): String {
    val data = ByteArray(bytes)
    ThreadLocalRandom.current().nextBytes(data)
    return data.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

internal fun headerTag(value: String?): String? = value?.let {
    Regex("(?:^|;)\\s*tag=([^;>\\s]+)", RegexOption.IGNORE_CASE).find(it)?.groupValues?.getOrNull(1)
}

internal fun headerUri(value: String?): String? {
    if (value == null) return null
    val bracketed = value.substringAfter('<', "").substringBefore('>', "")
    return (bracketed.ifEmpty { value.substringBefore(';') }).trim().ifEmpty { null }
}

/** Only provisional/success responses establish an early or confirmed dialog tag. */
internal fun responseEstablishesDialog(status: Int): Boolean = status in 101..299

internal object SdpMediaDirection {
    fun of(sdp: String, media: String): String {
        var inTarget = false
        var found = false
        var direction = "sendrecv"
        sdp.lineSequence().map { it.trim() }.forEach { line ->
            if (line.startsWith("m=", true)) {
                inTarget = line.startsWith("m=$media ", true)
                if (inTarget) {
                    found = true
                    direction = "sendrecv"
                }
            } else if (inTarget) {
                when {
                    line.equals("a=sendonly", true) -> direction = "sendonly"
                    line.equals("a=recvonly", true) -> direction = "recvonly"
                    line.equals("a=inactive", true) -> direction = "inactive"
                    line.equals("a=sendrecv", true) -> direction = "sendrecv"
                }
            }
        }
        return direction.takeIf { found } ?: "inactive"
    }
}

internal data class ViaMapping(val address: String, val port: Int) {
    companion object {
        fun parse(via: String?): ViaMapping? {
            if (via == null) return null
            val address = Regex("(?:^|;)\\s*received=([^;,\\s]+)", RegexOption.IGNORE_CASE)
                .find(via)?.groupValues?.getOrNull(1)?.trim('[', ']') ?: return null
            val port = Regex("(?:^|;)\\s*rport\\s*=\\s*(\\d+)", RegexOption.IGNORE_CASE)
                .find(via)?.groupValues?.getOrNull(1)?.toIntOrNull() ?: return null
            if (port !in 1..65535) return null
            return ViaMapping(address, port)
        }
    }
}
