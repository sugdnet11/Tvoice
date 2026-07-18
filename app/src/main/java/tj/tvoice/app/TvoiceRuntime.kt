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

    @Synchronized
    fun initialize(context: Context) {
        if (manager != null) return
        appContext = context.applicationContext
        manager = SipManager(appContext, this)
    }

    fun addObserver(observer: SipManager.Observer) {
        observers += observer
    }

    fun removeObserver(observer: SipManager.Observer) {
        observers -= observer
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
    fun toggleHold(): Boolean = requireManager().toggleHold()
    fun toggleMute(): Boolean = requireManager().toggleMute()
    fun toggleSpeaker(): Boolean = requireManager().toggleSpeaker()
    fun addToConference(number: String) = requireManager().addToConference(number)

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

    private fun requireManager(): SipManager = checkNotNull(manager) { "TvoiceRuntime не инициализирован" }
}
