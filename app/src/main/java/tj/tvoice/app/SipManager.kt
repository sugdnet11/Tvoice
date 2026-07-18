package tj.tvoice.app

import android.content.Context
import org.linphone.core.*

class SipManager(context: Context, private val observer: Observer) {
    interface Observer {
        fun onRegistration(state: RegistrationState, message: String)
        fun onCall(state: Call.State, remote: String, message: String)
    }

    private val factory = Factory.instance()
    private val core: Core = factory.createCore(null, null, context.applicationContext)
    private var account: Account? = null
    private val accounts = mutableMapOf<String, Account>()
    private var conferencePending = false

    private val listener = object : CoreListenerStub() {
        override fun onAccountRegistrationStateChanged(core: Core, account: Account, state: RegistrationState, message: String) {
            observer.onRegistration(state, message)
        }

        override fun onCallStateChanged(core: Core, call: Call, state: Call.State, message: String) {
            val remote = call.remoteAddress.username ?: call.remoteAddress.asStringUriOnly()
            if (conferencePending && state == Call.State.StreamsRunning && core.calls.size >= 2) {
                core.addAllToConference()
                conferencePending = false
            }
            observer.onCall(state, remote, message)
        }
    }

    init {
        core.addListener(listener)
        core.start()
    }

    fun login(username: String, password: String) {
        logout()
        addAccount(username, password)
    }

    fun addAccount(username: String, password: String) {
        val identity = factory.createAddress("sip:$username@${SipConfig.DOMAIN}") ?: error("Неверный SIP-номер")
        val server = factory.createAddress("sip:${SipConfig.DOMAIN}:${SipConfig.PORT};transport=${SipConfig.TRANSPORT}")
            ?: error("Неверный адрес сервера")
        val auth = factory.createAuthInfo(username, null, password, null, null, SipConfig.DOMAIN)
        core.addAuthInfo(auth)

        val params = core.createAccountParams().apply {
            identityAddress = identity
            serverAddress = server
            isRegisterEnabled = true
        }
        account = core.createAccount(params).also {
            core.addAccount(it)
            core.defaultAccount = it
            accounts[username] = it
        }
    }

    fun selectAccount(username: String) {
        accounts[username]?.let { core.defaultAccount = it; account = it }
    }

    fun call(number: String) {
        val address = factory.createAddress("sip:$number@${SipConfig.DOMAIN}") ?: error("Неверный номер")
        core.inviteAddress(address)
    }

    fun accept() { core.currentCall?.accept() }
    fun hangup() { core.currentCall?.terminate() }
    fun sendDtmf(digit: Char) { core.currentCall?.sendDtmf(digit) }
    fun toggleHold(): Boolean {
        val call = core.currentCall ?: return false
        val paused = call.state == Call.State.Paused
        if (paused) call.resume() else call.pause()
        return !paused
    }
    fun addToConference(number: String) {
        core.currentCall?.pause()
        conferencePending = true
        call(number)
    }
    fun toggleMute(): Boolean {
        val muted = core.isMicEnabled
        core.setMicEnabled(!muted)
        return muted
    }
    fun toggleSpeaker(): Boolean {
        val speaker = core.audioDevices.firstOrNull { it.type == AudioDevice.Type.Speaker }
        val earpiece = core.audioDevices.firstOrNull { it.type == AudioDevice.Type.Earpiece }
        val enabled = core.outputAudioDevice?.type != AudioDevice.Type.Speaker
        core.outputAudioDevice = if (enabled) speaker else earpiece
        return enabled
    }

    fun logout() {
        accounts.values.toList().forEach { core.removeAccount(it) }
        accounts.clear()
        account = null
        core.clearAllAuthInfo()
    }

    fun destroy() {
        core.removeListener(listener)
        core.stop()
    }
}
