package tj.tvoice.app

import android.content.Context
import java.util.concurrent.CopyOnWriteArraySet

/** Process-wide owner of the SIP engine. UI screens may come and go without dropping calls. */
object TvoiceRuntime : SipManager.Observer {
    private val observers = CopyOnWriteArraySet<SipManager.Observer>()
    private lateinit var appContext: Context
    private var manager: SipManager? = null
    private var pendingPassword = ""
    private var restoreStarted = false
    private val accountPasswords = linkedMapOf<String, String>()

    @Volatile var activeUsername: String = ""
        private set
    @Volatile var registrationState: RegistrationState = RegistrationState.None
        private set
    @Volatile var registrationMessage: String = ""
        private set
    @Volatile var callState: CallState = CallState.Idle
        private set
    @Volatile var remoteNumber: String = ""
        private set
    @Volatile var callMessage: String = ""
        private set
    @Volatile var isMainUiVisible: Boolean = false
        private set

    @Synchronized
    fun initialize(context: Context) {
        if (manager != null) return
        appContext = context.applicationContext
        ChatStore.initialize(appContext)
        manager = SipManager(appContext, this)
    }

    fun addObserver(observer: SipManager.Observer) {
        observers += observer
    }

    fun removeObserver(observer: SipManager.Observer) {
        observers -= observer
    }

    fun setMainUiVisible(visible: Boolean) {
        isMainUiVisible = visible
    }

    @Synchronized
    fun login(username: String, password: String) {
        val normalized = username.trim()
        activeUsername = normalized
        pendingPassword = password
        accountPasswords.clear()
        accountPasswords[normalized] = password
        restoreStarted = true
        requireManager().login(normalized, password)
    }

    @Synchronized
    fun addAccount(username: String, password: String) {
        val normalized = username.trim()
        activeUsername = normalized
        pendingPassword = password
        accountPasswords[normalized] = password
        restoreStarted = true
        requireManager().addAccount(normalized, password)
    }

    fun selectAccount(username: String) {
        activeUsername = username
        pendingPassword = accountPasswords[username].orEmpty()
        requireManager().selectAccount(username)
    }

    @Synchronized
    fun restoreSavedAccount(): Boolean {
        if (registrationState == RegistrationState.Ok || registrationState == RegistrationState.Progress) return true
        if (restoreStarted) return activeUsername.isNotBlank()
        val credentials = CredentialStore.load(appContext) ?: return false
        restoreStarted = true
        activeUsername = credentials.first
        pendingPassword = credentials.second
        accountPasswords.clear()
        accountPasswords[credentials.first] = credentials.second
        requireManager().login(credentials.first, credentials.second)
        return true
    }

    fun savedUsername(): String? = CredentialStore.username(appContext)
    fun call(number: String) = requireManager().call(number)
    fun accept() = requireManager().accept()
    fun hangup() = requireManager().hangup()
    fun sendDtmf(digit: Char) = requireManager().sendDtmf(digit)
    fun sendMessage(number: String, text: String) {
        val peer = number.trim()
        val body = text.trim()
        require(peer.isNotBlank()) { "Введите номер абонента" }
        require(body.isNotBlank()) { "Введите сообщение" }
        ChatStore.addOutgoing(activeUsername, peer, body)
        requireManager().sendMessage(peer, body)
    }
    fun toggleHold(): Boolean = requireManager().toggleHold()
    fun toggleMute(): Boolean = requireManager().toggleMute()
    fun toggleSpeaker(): Boolean = requireManager().toggleSpeaker()
    fun isMuted(): Boolean = requireManager().isMuted()
    fun isSpeakerEnabled(): Boolean = requireManager().isSpeakerEnabled()
    fun addToConference(number: String) = requireManager().addToConference(number)
    fun reconnectNetwork() {
        ChatStore.failSending()
        requireManager().reconnect()
    }

    @Synchronized
    fun logout() {
        requireManager().logout()
        CredentialStore.clear(appContext)
        activeUsername = ""
        pendingPassword = ""
        accountPasswords.clear()
        restoreStarted = false
        registrationState = RegistrationState.Cleared
        callState = CallState.Idle
        remoteNumber = ""
    }

    override fun onRegistration(state: RegistrationState, message: String) {
        registrationState = state
        registrationMessage = message
        if (state == RegistrationState.Ok && activeUsername.isNotBlank() && pendingPassword.isNotBlank()) {
            runCatching { CredentialStore.save(appContext, activeUsername, pendingPassword) }
        }
        if (state == RegistrationState.Failed) restoreStarted = false
        observers.forEach { observer -> runCatching { observer.onRegistration(state, message) } }
    }

    override fun onCall(state: CallState, remote: String, message: String) {
        callState = state
        remoteNumber = remote
        callMessage = message
        observers.forEach { observer -> runCatching { observer.onCall(state, remote, message) } }
        if (state == CallState.Released) callState = CallState.Idle
    }

    override fun onMessage(state: MessageState, remote: String, text: String, message: String) {
        when (state) {
            MessageState.Received -> ChatStore.addIncoming(activeUsername, remote, text)
            MessageState.Sent -> ChatStore.markLatest(activeUsername, remote, text, delivered = true)
            MessageState.Error -> ChatStore.markLatest(activeUsername, remote, text, delivered = false)
            MessageState.Sending -> Unit
        }
        observers.forEach { observer -> runCatching { observer.onMessage(state, remote, text, message) } }
    }

    private fun requireManager(): SipManager = checkNotNull(manager) { "TvoiceRuntime не инициализирован" }
}
