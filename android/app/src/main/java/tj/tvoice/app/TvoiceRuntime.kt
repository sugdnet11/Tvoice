package tj.tvoice.app

import android.content.Context
import android.view.Surface
import java.util.concurrent.CopyOnWriteArraySet

/** Process-wide owner of the SIP engine. UI screens may come and go without dropping calls. */
object TvoiceRuntime : SipManager.Observer, TvoiceController {
    private val observers = CopyOnWriteArraySet<SipManager.Observer>()
    private lateinit var appContext: Context
    private var manager: SipManager? = null
    private var pendingPassword = ""
    private var pendingAddedAccount: String? = null
    private var previousActiveAccount = ""
    private var restoreStarted = false
    private val accountPasswords = linkedMapOf<String, String>()

    @Volatile override var activeUsername: String = ""
        private set
    @Volatile override var registrationState: RegistrationState = RegistrationState.None
        private set
    @Volatile var registrationMessage: String = ""
        private set
    @Volatile override var callState: CallState = CallState.Idle
        private set
    @Volatile override var remoteNumber: String = ""
        private set
    @Volatile override var callConnectedAtMillis: Long? = null
        private set
    @Volatile var callMessage: String = ""
        private set
    @Volatile override var isMainUiVisible: Boolean = false
        private set
    override val isVideoCall: Boolean get() = manager?.isVideoCall == true

    @Synchronized
    fun initialize(context: Context) {
        if (manager != null) return
        appContext = context.applicationContext
        ChatStore.initialize(appContext)
        ChatClient.initialize(appContext)
        manager = SipManager(appContext, this)
        val stored = AccountStore.load(appContext)
        accountPasswords.putAll(stored.associate { it.username to it.password })
        manager?.restoreAccounts(stored)
    }

    override fun addObserver(observer: SipManager.Observer) {
        observers += observer
    }

    override fun removeObserver(observer: SipManager.Observer) {
        observers -= observer
    }

    override fun setMainUiVisible(visible: Boolean) {
        isMainUiVisible = visible
    }

    @Synchronized
    override fun login(username: String, password: String) {
        val normalized = username.trim()
        AccountStore.clear(appContext)
        pendingAddedAccount = null
        previousActiveAccount = ""
        activeUsername = normalized
        pendingPassword = password
        accountPasswords.clear()
        accountPasswords[normalized] = password
        restoreStarted = true
        requireManager().login(normalized, password)
    }

    @Synchronized
    override fun addAccount(username: String, password: String) {
        val normalized = username.trim()
        require(normalized.isNotBlank()) { "Введите SIP-номер" }
        require(password.isNotBlank()) { "Введите пароль" }
        previousActiveAccount = activeUsername
        pendingAddedAccount = normalized
        activeUsername = normalized
        pendingPassword = password
        accountPasswords[normalized] = password
        restoreStarted = true
        requireManager().addAccount(normalized, password)
    }

    @Synchronized
    override fun selectAccount(username: String) {
        require(accountPasswords.containsKey(username)) { "Аккаунт $username не найден" }
        pendingAddedAccount = null
        previousActiveAccount = ""
        activeUsername = username
        pendingPassword = accountPasswords[username].orEmpty()
        requireManager().selectAccount(username)
    }

    @Synchronized
    override fun restoreSavedAccount(): Boolean {
        if (registrationState == RegistrationState.Ok || registrationState == RegistrationState.Progress) return true
        if (restoreStarted) return activeUsername.isNotBlank()
        val credentials = accountPasswords.entries.firstOrNull()
            ?.let { it.key to it.value } ?: return false
        restoreStarted = true
        activeUsername = credentials.first
        pendingPassword = credentials.second
        requireManager().restoreAccounts(accountPasswords.map { SipAccount(it.key, it.value) })
        requireManager().selectAccount(credentials.first)
        return true
    }

    @Synchronized override fun savedUsername(): String? = accountPasswords.keys.firstOrNull()
    @Synchronized override fun accountUsernames(): List<String> = accountPasswords.keys.toList()
    override fun call(number: String) = requireManager().call(number)
    override fun videoCall(number: String) = requireManager().videoCall(number)
    override fun accept() = requireManager().accept()
    override fun hangup() = requireManager().hangup()
    override fun sendDtmf(digit: Char) = requireManager().sendDtmf(digit)
    override fun sendMessage(number: String, text: String) {
        val peer = SipIdentity.requireValid(number)
        val body = text.trim()
        require(peer.isNotBlank()) { "Введите номер абонента" }
        require(body.isNotBlank()) { "Введите сообщение" }
        ChatClient.sendMessage(peer, body)
    }
    override fun toggleHold(): Boolean = requireManager().toggleHold()
    override fun toggleMute(): Boolean = requireManager().toggleMute()
    override fun toggleSpeaker(): Boolean = requireManager().toggleSpeaker()
    override fun isMuted(): Boolean = requireManager().isMuted()
    override fun isSpeakerEnabled(): Boolean = requireManager().isSpeakerEnabled()
    override fun isVideoCameraEnabled(): Boolean = requireManager().isVideoCameraEnabled()
    override fun videoCameraRotationDegrees(): Int = requireManager().videoCameraRotationDegrees()
    override fun isFrontVideoCamera(): Boolean = requireManager().isFrontVideoCamera()
    override fun toggleVideoCamera(): Boolean = requireManager().toggleVideoCamera()
    override fun switchVideoCamera(): Boolean = requireManager().switchVideoCamera()
    override fun setVideoSurfaces(localPreview: Surface?, remoteRender: Surface?) =
        requireManager().setVideoSurfaces(localPreview, remoteRender)
    override fun supportsConference(): Boolean = requireManager().supportsConference()
    fun reconnectNetwork() {
        ChatStore.failSending()
        requireManager().reconnect()
        ChatClient.reconnect()
    }

    @Synchronized
    override fun logout() {
        requireManager().logout()
        ChatClient.logout()
        AccountStore.clear(appContext)
        activeUsername = ""
        pendingPassword = ""
        accountPasswords.clear()
        pendingAddedAccount = null
        previousActiveAccount = ""
        restoreStarted = false
        registrationState = RegistrationState.Cleared
        callState = CallState.Idle
        remoteNumber = ""
        callConnectedAtMillis = null
    }

    @Synchronized
    override fun onRegistration(state: RegistrationState, message: String) {
        registrationState = state
        registrationMessage = message
        if (state == RegistrationState.Ok && activeUsername.isNotBlank() && pendingPassword.isNotBlank()) {
            runCatching { AccountStore.upsert(appContext, SipAccount(activeUsername, pendingPassword)) }
            ChatClient.login(activeUsername, pendingPassword)
            pendingAddedAccount = null
            previousActiveAccount = ""
        }
        if (state == RegistrationState.Failed && isFatalRegistrationFailure(message)) {
            val rejected = pendingAddedAccount
            if (rejected != null) {
                accountPasswords.remove(rejected)
                runCatching { AccountStore.remove(appContext, rejected) }
                val fallback = previousActiveAccount.takeIf(accountPasswords::containsKey)
                    ?: accountPasswords.keys.firstOrNull().orEmpty()
                pendingAddedAccount = null
                previousActiveAccount = ""
                activeUsername = fallback
                pendingPassword = accountPasswords[fallback].orEmpty()
                requireManager().restoreAccounts(accountPasswords.map { SipAccount(it.key, it.value) })
                if (fallback.isNotBlank()) requireManager().selectAccount(fallback)
            }
        }
        if (state == RegistrationState.Failed) restoreStarted = false
        observers.forEach { observer -> runCatching { observer.onRegistration(state, message) } }
    }

    override fun onCall(state: CallState, remote: String, message: String) {
        if (state == CallState.Connected || state == CallState.StreamsRunning) {
            if (callConnectedAtMillis == null) callConnectedAtMillis = System.currentTimeMillis()
        }
        callState = state
        remoteNumber = remote
        callMessage = message
        observers.forEach { observer -> runCatching { observer.onCall(state, remote, message) } }
        if (state in setOf(CallState.End, CallState.Error, CallState.Released)) {
            callConnectedAtMillis = null
        }
        if (state == CallState.Released) callState = CallState.Idle
    }

    override fun onMessage(state: MessageState, remote: String, text: String, message: String) {
        when (state) {
            MessageState.Received -> ChatStore.addIncoming(SipIdentity.normalize(activeUsername), SipIdentity.normalize(remote), text)
            MessageState.Sent -> ChatStore.markLatest(SipIdentity.normalize(activeUsername), SipIdentity.normalize(remote), text, delivered = true)
            MessageState.Error -> ChatStore.markLatest(SipIdentity.normalize(activeUsername), SipIdentity.normalize(remote), text, delivered = false)
            MessageState.Sending -> Unit
        }
        observers.forEach { observer -> runCatching { observer.onMessage(state, remote, text, message) } }
    }

    private fun requireManager(): SipManager = checkNotNull(manager) { "TvoiceRuntime не инициализирован" }

    private fun isFatalRegistrationFailure(message: String): Boolean =
        message.contains("логин", ignoreCase = true) ||
            message.contains("пароль", ignoreCase = true) ||
            message.startsWith("SIP 401") ||
            message.startsWith("SIP 403") ||
            message.startsWith("SIP 404")
}
