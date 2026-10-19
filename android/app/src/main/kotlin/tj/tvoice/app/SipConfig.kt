package tj.tvoice.app

object SipConfig {
    @Volatile var DOMAIN = "185.177.2.115"
        private set
    @Volatile var PORT = 5060
        private set
    @Volatile var TRANSPORT = "udp"
        private set

    @Synchronized
    fun configure(domain: String, port: Int, transport: String): Boolean {
        val normalizedDomain = domain.trim()
        val normalizedTransport = transport.trim().lowercase()
        require(normalizedDomain.isNotBlank()) { "Не указан SIP-сервер компании" }
        require(port in 1..65535) { "Некорректный порт SIP-сервера" }
        require(normalizedTransport == "udp") {
            "Эта версия Android поддерживает SIP-транспорт UDP"
        }
        val changed = DOMAIN != normalizedDomain || PORT != port || TRANSPORT != normalizedTransport
        DOMAIN = normalizedDomain
        PORT = port
        TRANSPORT = normalizedTransport
        return changed
    }
}
