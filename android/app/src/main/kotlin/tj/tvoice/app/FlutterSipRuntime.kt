package tj.tvoice.app

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import androidx.core.content.ContextCompat

internal data class SipAccount(val username: String, val password: String)

/** Process-wide SIP owner. Recreating Flutter screens does not stop a call. */
object FlutterSipRuntime : SipManager.Observer, EventChannel.StreamHandler {
    const val METHOD_CHANNEL = "tj.tvoice/sip"
    const val EVENT_CHANNEL = "tj.tvoice/sip_events"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var manager: SipManager? = null
    private var appContext: Context? = null
    private var incomingRingtone: Ringtone? = null
    private var sink: EventChannel.EventSink? = null
    private var registrationState = RegistrationState.None
    private var registrationMessage = ""
    private var callState = CallState.Idle
    private var remoteNumber = ""
    private var callMessage = ""
    private var connectedAtMillis: Long? = null

    @Synchronized
    fun initialize(context: Context) {
        if (manager != null) return
        appContext = context.applicationContext
        manager = SipManager(context.applicationContext, this)
    }

    @Synchronized
    fun register(number: String, password: String) {
        require(number.isNotBlank()) { "Введите SIP-номер" }
        require(password.isNotBlank()) { "Введите пароль" }
        registrationState = RegistrationState.Progress
        emitRegistration()
        appContext?.let { context ->
            ContextCompat.startForegroundService(
                context,
                Intent(context, FlutterSipService::class.java),
            )
        }
        requireManager().login(number, password)
    }

    fun call(number: String) {
        require(number.isNotBlank()) { "Введите номер абонента" }
        requireManager().call(number)
    }

    fun answer() = requireManager().accept()
    fun hangup() = requireManager().hangup()

    fun unregister() {
        stopIncomingRingtone()
        requireManager().logout()
        registrationState = RegistrationState.None
        registrationMessage = "SIP отключён"
        callState = CallState.Idle
        remoteNumber = ""
        callMessage = ""
        connectedAtMillis = null
        emitRegistration()
        appContext?.let { context ->
            FlutterSipService.cancelIncoming(context)
            context.stopService(Intent(context, FlutterSipService::class.java))
        }
    }

    fun setMuted(muted: Boolean) {
        val manager = requireManager()
        if (manager.isMuted() != muted) manager.toggleMute()
    }

    fun setSpeaker(enabled: Boolean) {
        val manager = requireManager()
        if (manager.isSpeakerEnabled() != enabled) manager.toggleSpeaker()
    }

    fun setHeld(held: Boolean) {
        val manager = requireManager()
        val currentlyHeld = callState == CallState.Paused
        if (currentlyHeld != held) manager.toggleHold()
    }

    fun snapshot(): Map<String, Any?> = mapOf(
        "registrationState" to registrationState.name,
        "registrationMessage" to registrationMessage,
        "callState" to callState.name,
        "remoteNumber" to remoteNumber,
        "callMessage" to callMessage,
        "connectedAtMillis" to connectedAtMillis,
    )

    override fun onRegistration(state: RegistrationState, message: String) {
        registrationState = state
        registrationMessage = message
        appContext?.let { FlutterSipService.updateStatus(it, message) }
        emitRegistration()
    }

    override fun onCall(state: CallState, remote: String, message: String) {
        callState = state
        remoteNumber = remote
        callMessage = message
        if (state == CallState.IncomingReceived) {
            playIncomingRingtone()
            appContext?.let { FlutterSipService.showIncoming(it, remote) }
        } else {
            stopIncomingRingtone()
            appContext?.let { FlutterSipService.cancelIncoming(it) }
        }
        appContext?.let { context ->
            if (state == CallState.Connected || state == CallState.StreamsRunning) {
                FlutterSipService.updateStatus(context, "Разговор с $remote")
            } else if (state in setOf(CallState.End, CallState.Error, CallState.Released)) {
                FlutterSipService.updateStatus(context, "SIP подключён")
            }
        }
        if (state == CallState.Connected || state == CallState.StreamsRunning) {
            if (connectedAtMillis == null) connectedAtMillis = System.currentTimeMillis()
        }
        emit(
            mapOf(
                "type" to "call",
                "state" to state.name,
                "remoteNumber" to remote,
                "message" to message,
                "connectedAtMillis" to connectedAtMillis,
            ),
        )
        if (state in setOf(CallState.End, CallState.Error, CallState.Released)) {
            connectedAtMillis = null
        }
        if (state == CallState.Released) callState = CallState.Idle
    }

    override fun onMessage(
        state: MessageState,
        remote: String,
        text: String,
        message: String,
    ) = Unit

    private fun emitRegistration() {
        emit(
            mapOf(
                "type" to "registration",
                "state" to registrationState.name,
                "message" to registrationMessage,
            ),
        )
    }

    private fun playIncomingRingtone() {
        if (incomingRingtone?.isPlaying == true) return
        val context = appContext ?: return
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        incomingRingtone = RingtoneManager.getRingtone(context, uri)?.apply {
            audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isLooping = true
            play()
        }
    }

    private fun stopIncomingRingtone() {
        incomingRingtone?.stop()
        incomingRingtone = null
    }

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post { sink?.success(event) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        emit(mapOf("type" to "snapshot", "value" to snapshot()))
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun requireManager(): SipManager = checkNotNull(manager) {
        "SIP engine is not initialized"
    }
}
