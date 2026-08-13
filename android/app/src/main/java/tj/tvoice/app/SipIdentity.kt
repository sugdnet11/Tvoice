package tj.tvoice.app

/** Canonical key shared by SIP, device contacts, chat cache and the chat API. */
internal object SipIdentity {
    fun normalize(raw: String): String {
        var value = raw.trim()
        if (value.startsWith("sip:", ignoreCase = true)) value = value.substring(4)
        value = value.substringBefore('@').substringBefore(';').trim()
        if (value.matches(PHONE_LIKE)) value = value.filter(Char::isDigit)
        return value
    }

    fun requireValid(raw: String): String {
        val normalized = normalize(raw)
        require(normalized.length in 2..64 && normalized.matches(SIP_USER)) {
            "Некорректный SIP-номер абонента"
        }
        return normalized
    }

    private val PHONE_LIKE = Regex("^\\+?[0-9\\s().-]+$")
    private val SIP_USER = Regex("[A-Za-z0-9_.!~*'()%+-]+")
}
