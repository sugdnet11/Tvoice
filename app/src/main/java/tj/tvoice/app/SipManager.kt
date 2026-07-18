package tj.tvoice.app

import android.content.Context

/**
 * Stable UI-facing API for the Tvoice protocol engine.
 *
 * No third-party SIP SDK is used here. TvoiceSipCore implements SIP signaling,
 * Digest authentication and G.711/RTP audio inside this project.
 */
class SipManager(context: Context, private val observer: Observer) {
    interface Observer {
        fun onRegistration(state: RegistrationState, message: String)
        fun onCall(state: CallState, remote: String, message: String)
    }

    private data class Credentials(val username: String, val password: String)

    private val accounts = linkedMapOf<String, Credentials>()
    private var activeAccount: String? = null
    private val core = TvoiceSipCore(context, object : TvoiceSipCore.Listener {
        override fun onRegistration(state: RegistrationState, message: String) {
            observer.onRegistration(state, message)
        }

        override fun onCall(state: CallState, remote: String, message: String) {
            observer.onCall(state, remote, message)
        }
    })

    fun login(username: String, password: String) {
        accounts.clear()
        addAccount(username, password)
    }

    fun addAccount(username: String, password: String) {
        val normalized = username.trim()
        require(normalized.isNotBlank()) { "Введите SIP-номер" }
        require(password.isNotBlank()) { "Введите пароль" }
        accounts[normalized] = Credentials(normalized, password)
        activeAccount = normalized
        core.register(normalized, password)
    }

    fun selectAccount(username: String) {
        val credentials = accounts[username] ?: error("Аккаунт $username не найден")
        activeAccount = username
        core.register(credentials.username, credentials.password)
    }

    fun call(number: String) = core.call(number)
    fun accept() = core.accept()
    fun hangup() = core.hangup()
    fun sendDtmf(digit: Char) = core.sendDtmf(digit)
    fun toggleHold(): Boolean = core.toggleHold()
    fun toggleMute(): Boolean = core.toggleMute()
    fun toggleSpeaker(): Boolean = core.toggleSpeaker()

    fun addToConference(number: String) {
        throw IllegalStateException("Локальная конференция с $number будет включена после проверки нового Tvoice SIP Core")
    }

    fun logout() {
        core.unregister()
        accounts.clear()
        activeAccount = null
    }

    fun destroy() = core.close()
}
