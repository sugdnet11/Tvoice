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
        fun onMessage(state: MessageState, remote: String, text: String, message: String) = Unit
    }

    private data class Credentials(val username: String, val password: String)

    private val appContext = context.applicationContext
    private val accounts = linkedMapOf<String, Credentials>()
    private var activeAccount: String? = null
    private var coreGeneration = 0
    private var lastCallState = CallState.Idle
    private var lastRemote = ""
    private var core = createCore()

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

    /** Recreates UDP/RTP sockets after Android switches between Wi-Fi and mobile data. */
    @Synchronized
    fun reconnect() {
        val credentials = activeAccount?.let(accounts::get) ?: return
        val previousCore = core
        coreGeneration += 1 // Ignore late callbacks from the socket being replaced.
        if (lastCallState !in setOf(CallState.Idle, CallState.End, CallState.Error, CallState.Released)) {
            observer.onCall(CallState.End, lastRemote, "Сеть изменилась")
            observer.onCall(CallState.Released, lastRemote, "Сеть изменилась")
        }
        lastCallState = CallState.Idle
        lastRemote = ""
        previousCore.close()
        core = createCore()
        observer.onRegistration(RegistrationState.Progress, "Восстановление SIP после смены сети…")
        core.register(credentials.username, credentials.password)
    }

    fun call(number: String) = core.call(number)
    fun accept() = core.accept()
    fun hangup() = core.hangup()
    fun sendDtmf(digit: Char) = core.sendDtmf(digit)
    fun sendMessage(number: String, text: String) = core.sendMessage(number, text)
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

    private fun createCore(): TvoiceSipCore {
        coreGeneration += 1
        val generation = coreGeneration
        return TvoiceSipCore(appContext, object : TvoiceSipCore.Listener {
            override fun onRegistration(state: RegistrationState, message: String) {
                if (generation == coreGeneration) observer.onRegistration(state, message)
            }

            override fun onCall(state: CallState, remote: String, message: String) {
                if (generation != coreGeneration) return
                lastCallState = state
                lastRemote = remote
                observer.onCall(state, remote, message)
            }

            override fun onMessage(state: MessageState, remote: String, text: String, message: String) {
                if (generation == coreGeneration) observer.onMessage(state, remote, text, message)
            }
        })
    }
}
