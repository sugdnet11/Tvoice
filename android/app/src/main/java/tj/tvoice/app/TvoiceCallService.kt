package tj.tvoice.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/** Keeps SIP/UDP registration alive and exposes calls through Android's native call UI. */
class TvoiceCallService : Service(), SipManager.Observer, ChatClient.Observer {
    @Volatile private var activeVideoInvite: ChatClient.VideoCallInvite? = null
    private var incomingTone: ToneGenerator? = null
    private var incomingTonePlaying = false
    private var ringtoneFocusRequest: AudioFocusRequest? = null
    private var ringbackTone: ToneGenerator? = null
    private var ringbackPlaying = false
    private val ringbackPulse = object : Runnable {
        override fun run() {
            if (!ringbackPlaying) return
            releaseCurrentRingbackTone()
            val tone = runCatching { ToneGenerator(AudioManager.STREAM_VOICE_CALL, 72) }.getOrNull()
            ringbackTone = tone
            // Never hand an unlimited tone to vendor audio firmware. Even if a
            // stop callback is lost, this pulse ends by itself after one second.
            runCatching { tone?.startTone(ToneGenerator.TONE_SUP_RINGTONE, RINGBACK_PULSE_MS) }
            mainHandler.postDelayed(this, RINGBACK_CYCLE_MS)
        }
    }
    private val incomingTonePulse = object : Runnable {
        override fun run() {
            if (!incomingTonePlaying || answerOrDeclinePending ||
                (TvoiceRuntime.callState != CallState.IncomingReceived && activeVideoInvite == null)
            ) return
            releaseCurrentIncomingTone()
            val tone = runCatching { ToneGenerator(AudioManager.STREAM_RING, 78) }.getOrNull()
            incomingTone = tone
            // A finite pulse is a hard OEM-independent safety limit: even if a
            // later stop callback is lost, the ringtone cannot continue forever.
            runCatching { tone?.startTone(ToneGenerator.TONE_SUP_RINGTONE, INCOMING_TONE_PULSE_MS) }
            mainHandler.postDelayed(this, INCOMING_TONE_CYCLE_MS)
        }
    }
    @Volatile private var answerOrDeclinePending = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var connectivityManager: ConnectivityManager
    @Volatile private var currentNetwork: Network? = null
    private var networkCallbackRegistered = false
    private val reconnectAfterNetworkChange = Runnable {
        if (currentNetwork != null && TvoiceRuntime.activeUsername.isNotBlank()) {
            TvoiceRuntime.reconnectNetwork()
        }
    }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val changed = currentNetwork != null && currentNetwork != network
            val restored = currentNetwork == null
            currentNetwork = network
            if (changed || restored) scheduleNetworkReconnect()
        }

        override fun onLost(network: Network) {
            if (currentNetwork == network) currentNetwork = null
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
        notificationManager().cancel(CALL_NOTIFICATION_ID)
        TvoiceRuntime.initialize(this)
        TvoiceRuntime.addObserver(this)
        ChatClient.addObserver(this)
        connectivityManager = getSystemService(ConnectivityManager::class.java)
        currentNetwork = connectivityManager.activeNetwork
        connectivityManager.registerDefaultNetworkCallback(networkCallback)
        networkCallbackRegistered = true
        updateServiceNotification("Подготовка SIP-соединения…")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> Unit
            ACTION_ANSWER -> {
                // Stop the locally owned ringtone before queuing the SIP 200 OK.
                // Calling accept() directly from an Activity left a race where the
                // Activity's onResume could start the ringtone again.
                answerOrDeclinePending = true
                stopIncomingAlerts()
                notificationManager().cancel(CALL_NOTIFICATION_ID)
                TvoiceRuntime.accept()
            }
            ACTION_INCOMING_SCREEN_VISIBLE -> {
                if ((TvoiceRuntime.callState == CallState.IncomingReceived || activeVideoInvite != null) &&
                    !answerOrDeclinePending
                ) {
                    notificationManager().cancel(CALL_NOTIFICATION_ID)
                    startIncomingAlerts()
                }
            }
            ACTION_SETTINGS_CHANGED -> {
                stopIncomingAlerts()
                if (TvoiceRuntime.callState == CallState.IncomingReceived && !answerOrDeclinePending) {
                    startIncomingAlerts()
                }
            }
            ACTION_VIDEO_STATE_CHANGED -> {
                if (TvoiceRuntime.callState in setOf(CallState.Connected, CallState.StreamsRunning, CallState.Paused)) {
                    showOngoingCall(
                        TvoiceRuntime.remoteNumber,
                        onHold = TvoiceRuntime.callState == CallState.Paused
                    )
                }
            }
            ACTION_VIDEO_ALERT_STOP -> {
                answerOrDeclinePending = true
                stopIncomingAlerts()
                notificationManager().cancel(CALL_NOTIFICATION_ID)
                activeVideoInvite = null
            }
            ACTION_VIDEO_DECLINE -> {
                answerOrDeclinePending = true
                stopIncomingAlerts()
                notificationManager().cancel(CALL_NOTIFICATION_ID)
                val callId = intent.getStringExtra(EXTRA_VIDEO_CALL_ID)
                    ?: activeVideoInvite?.callId
                if (!callId.isNullOrBlank()) ChatClient.rejectVideoCall(callId)
                activeVideoInvite = null
            }
            ACTION_DECLINE, ACTION_HANGUP -> {
                answerOrDeclinePending = true
                stopIncomingAlerts()
                notificationManager().cancel(CALL_NOTIFICATION_ID)
                TvoiceRuntime.hangup()
            }
            ACTION_RESTORE, null -> TvoiceRuntime.restoreSavedAccount()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopIncomingAlerts()
        releaseRingbackTone()
        mainHandler.removeCallbacks(reconnectAfterNetworkChange)
        if (networkCallbackRegistered) {
            runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
            networkCallbackRegistered = false
        }
        TvoiceRuntime.removeObserver(this)
        ChatClient.removeObserver(this)
        super.onDestroy()
    }

    private fun scheduleNetworkReconnect() {
        mainHandler.removeCallbacks(reconnectAfterNetworkChange)
        mainHandler.postDelayed(reconnectAfterNetworkChange, 1_500)
    }

    override fun onRegistration(state: RegistrationState, message: String) {
        if (state == RegistrationState.Cleared || state == RegistrationState.Failed) {
            answerOrDeclinePending = true
            stopIncomingAlerts()
            stopRingbackTone()
            notificationManager().cancel(CALL_NOTIFICATION_ID)
        } else if (state == RegistrationState.Ok && TvoiceRuntime.callState == CallState.Idle) {
            answerOrDeclinePending = false
        }
        val text = when (state) {
            RegistrationState.Ok -> "${TvoiceRuntime.activeUsername} • в сети"
            RegistrationState.Progress -> "Подключение к SIP…"
            RegistrationState.Failed -> "Нет связи: $message"
            RegistrationState.Cleared -> "SIP отключён"
            RegistrationState.None -> "Подготовка SIP-соединения…"
        }
        updateServiceNotification(text)
    }

    override fun onCall(state: CallState, remote: String, message: String) {
        when (state) {
            CallState.OutgoingInit -> {
                answerOrDeclinePending = false
                stopRingbackTone()
            }
            CallState.OutgoingProgress, CallState.OutgoingRinging -> startRingbackTone()
            CallState.IncomingReceived -> {
                stopRingbackTone()
                stopIncomingAlerts()
                if (!answerOrDeclinePending) startIncomingAlerts()
                if (TvoiceRuntime.isMainUiVisible) {
                    notificationManager().cancel(CALL_NOTIFICATION_ID)
                } else if (callNotificationsEnabled()) {
                    showIncomingCall(remote)
                }
            }
            CallState.Connected, CallState.StreamsRunning, CallState.Paused -> {
                answerOrDeclinePending = true
                stopRingbackTone()
                stopIncomingAlerts()
                showOngoingCall(remote, onHold = state == CallState.Paused)
            }
            CallState.End, CallState.Error, CallState.Released -> {
                stopRingbackTone()
                stopIncomingAlerts()
                notificationManager().cancel(CALL_NOTIFICATION_ID)
                updateServiceNotification("${TvoiceRuntime.activeUsername} • в сети")
                answerOrDeclinePending = false
            }
            else -> Unit
        }
    }

    override fun onMessage(state: MessageState, remote: String, text: String, message: String) {
        if (state != MessageState.Received || TvoiceRuntime.isMainUiVisible || !chatNotificationsEnabled()) return
        showChatNotification(remote, text)
    }

    override fun onChatMessage(message: ChatMessage) {
        if (!message.incoming || TvoiceRuntime.isMainUiVisible || !chatNotificationsEnabled()) return
        showChatNotification(message.peer, message.text)
    }

    override fun onIncomingVideoCall(invite: ChatClient.VideoCallInvite) {
        if (TvoiceRuntime.callState !in setOf(CallState.Idle, CallState.End, CallState.Released)) {
            ChatClient.rejectVideoCall(invite.callId)
            return
        }
        activeVideoInvite = invite
        answerOrDeclinePending = false
        stopIncomingAlerts()
        startIncomingAlerts()
        // An unlocked Android device normally shows a CallStyle notification for
        // only a few seconds. Open our persistent call screen as well; the
        // notification remains a fallback for OEMs that block background starts.
        if (!TvoiceRuntime.isMainUiVisible) {
            runCatching {
                startActivity(
                    VideoCallActivity.incomingIntent(this, invite).addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                    )
                )
            }
        }
        if (callNotificationsEnabled()) showIncomingVideoCall(invite)
    }

    override fun onVideoCallEnded(callId: String, reason: String) {
        if (activeVideoInvite?.callId != callId) return
        activeVideoInvite = null
        answerOrDeclinePending = true
        stopIncomingAlerts()
        notificationManager().cancel(CALL_NOTIFICATION_ID)
    }

    private fun showChatNotification(remote: String, text: String) {
        val open = PendingIntent.getActivity(
            this,
            3000 + remote.hashCode().and(0x7fff),
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(MainActivity.EXTRA_OPEN_CHAT, remote),
            immutableUpdateFlags()
        )
        val notification = Notification.Builder(this, CHAT_CHANNEL)
            .setSmallIcon(R.drawable.ic_chat)
            .setContentTitle(remote)
            .setContentText(text)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setColor(Color.rgb(26, 76, 221))
            .build()
        notificationManager().notify(CHAT_NOTIFICATION_BASE + remote.hashCode().and(0x0fff), notification)
    }

    private fun updateServiceNotification(text: String) {
        val notification = serviceNotification(text)
        startTypedForeground(notification, callAudio = false)
    }

    private fun serviceNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            immutableFlags()
        )
        return Notification.Builder(this, SERVICE_CHANNEL)
            .setSmallIcon(R.drawable.ic_call)
            .setContentTitle("Tvoice работает")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setColor(Color.rgb(26, 76, 221))
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                }
            }
            .build()
    }

    private fun showIncomingCall(remote: String) {
        val fullScreen = PendingIntent.getActivity(
            this,
            10,
            IncomingCallActivity.showIntent(this, remote),
            immutableUpdateFlags()
        )
        // Answer inside the foreground service. Starting the call Activity first can
        // run its onResume after the answer action and start the ringtone again.
        val answer = servicePendingIntent(11, ACTION_ANSWER)
        val decline = servicePendingIntent(12, ACTION_DECLINE)
        val builder = Notification.Builder(this, INCOMING_CALL_CHANNEL)
            .setSmallIcon(R.drawable.ic_call)
            .setContentTitle(if (TvoiceRuntime.isVideoCall) "Входящий видеозвонок" else "Входящий звонок")
            .setContentText(remote)
            .setContentIntent(fullScreen)
            .setFullScreenIntent(fullScreen, true)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setColor(Color.rgb(26, 76, 221))
            .setTimeoutAfter(60_000)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName(remote)
                .setImportant(true)
                .setIcon(Icon.createWithResource(this, R.drawable.ic_account))
                .build()
            builder.setStyle(Notification.CallStyle.forIncomingCall(person, decline, answer))
        } else {
            builder.addAction(Notification.Action.Builder(R.drawable.ic_call_end, "Отклонить", decline).build())
            builder.addAction(Notification.Action.Builder(R.drawable.ic_call, "Ответить", answer).build())
        }
        notificationManager().notify(CALL_NOTIFICATION_ID, builder.build())
    }

    private fun showIncomingVideoCall(invite: ChatClient.VideoCallInvite) {
        val fullScreen = PendingIntent.getActivity(
            this,
            30,
            VideoCallActivity.incomingIntent(this, invite)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            immutableUpdateFlags()
        )
        val decline = PendingIntent.getService(
            this,
            31,
            Intent(this, TvoiceCallService::class.java)
                .setAction(ACTION_VIDEO_DECLINE)
                .putExtra(EXTRA_VIDEO_CALL_ID, invite.callId),
            immutableUpdateFlags()
        )
        val builder = Notification.Builder(this, INCOMING_CALL_CHANNEL)
            .setSmallIcon(R.drawable.ic_videocam)
            .setContentTitle("Входящий видеозвонок")
            .setContentText(invite.peerName.ifBlank { invite.peerNumber })
            .setContentIntent(fullScreen)
            .setFullScreenIntent(fullScreen, true)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setTimeoutAfter(120_000)
            .setColor(Color.rgb(26, 76, 221))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName(invite.peerName.ifBlank { invite.peerNumber })
                .setImportant(true)
                .build()
            builder.setStyle(Notification.CallStyle.forIncomingCall(person, decline, fullScreen))
        } else {
            builder.addAction(Notification.Action.Builder(R.drawable.ic_call_end, "Отклонить", decline).build())
            builder.addAction(Notification.Action.Builder(R.drawable.ic_call, "Ответить", fullScreen).build())
        }
        notificationManager().notify(CALL_NOTIFICATION_ID, builder.build())
    }

    @Synchronized
    private fun startManualRingtone() {
        if (answerOrDeclinePending ||
            (TvoiceRuntime.callState != CallState.IncomingReceived && activeVideoInvite == null)) return
        if (!preferences().getBoolean(PREF_RINGTONE_ENABLED, true)) return
        if (incomingTonePlaying) return
        val audioManager = getSystemService(AudioManager::class.java)
        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .setOnAudioFocusChangeListener { change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                    stopManualRingtone()
                }
            }
            .build()
        // Several Android 14/15 vendor builds deny exclusive focus while a
        // full-screen incoming-call Activity is being opened. STREAM_RING can
        // still play correctly, so focus denial must not silence video calls.
        if (audioManager.requestAudioFocus(focusRequest) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            ringtoneFocusRequest = focusRequest
        }
        incomingTonePlaying = true
        mainHandler.removeCallbacks(incomingTonePulse)
        mainHandler.post(incomingTonePulse)
    }

    @Synchronized
    private fun stopManualRingtone() {
        incomingTonePlaying = false
        mainHandler.removeCallbacks(incomingTonePulse)
        releaseCurrentIncomingTone()
        ringtoneFocusRequest?.let { request ->
            runCatching { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(request) }
        }
        ringtoneFocusRequest = null
    }

    private fun releaseCurrentIncomingTone() {
        runCatching { incomingTone?.stopTone() }
        runCatching { incomingTone?.release() }
        incomingTone = null
    }

    @Synchronized
    private fun startRingbackTone() {
        if (ringbackPlaying) return
        ringbackPlaying = true
        mainHandler.removeCallbacks(ringbackPulse)
        mainHandler.post(ringbackPulse)
    }

    @Synchronized
    private fun stopRingbackTone() {
        ringbackPlaying = false
        mainHandler.removeCallbacks(ringbackPulse)
        releaseCurrentRingbackTone()
    }

    private fun releaseCurrentRingbackTone() {
        runCatching { ringbackTone?.stopTone() }
        runCatching { ringbackTone?.release() }
        ringbackTone = null
    }

    @Synchronized
    private fun releaseRingbackTone() {
        stopRingbackTone()
    }

    @Synchronized
    private fun startIncomingAlerts() {
        if (answerOrDeclinePending ||
            (TvoiceRuntime.callState != CallState.IncomingReceived && activeVideoInvite == null)) return
        startManualRingtone()
        if (!preferences().getBoolean(PREF_VIBRATION_ENABLED, true)) return
        val pattern = longArrayOf(0, 450, 250, 450)
        val effect = VibrationEffect.createWaveform(pattern, 0)
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .build()
        runCatching { vibrator().vibrate(effect, attributes) }
    }

    @Synchronized
    private fun stopIncomingAlerts() {
        stopManualRingtone()
        runCatching { vibrator().cancel() }
    }

    @Suppress("DEPRECATION")
    private fun vibrator(): Vibrator =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }

    private fun preferences() = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
    private fun callNotificationsEnabled(): Boolean =
        preferences().getBoolean(PREF_CALL_NOTIFICATIONS_ENABLED, true)
    private fun chatNotificationsEnabled(): Boolean =
        preferences().getBoolean(PREF_CHAT_NOTIFICATIONS_ENABLED, true)

    private fun showOngoingCall(remote: String, onHold: Boolean) {
        val hangup = servicePendingIntent(20, ACTION_HANGUP)
        val open = PendingIntent.getActivity(
            this,
            21,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            immutableUpdateFlags()
        )
        val builder = Notification.Builder(this, ACTIVE_CALL_CHANNEL)
            .setSmallIcon(R.drawable.ic_call)
            .setContentTitle(remote)
            .setContentText(
                when {
                    onHold -> "Звонок на удержании"
                    TvoiceRuntime.isVideoCall -> "Активный видеозвонок"
                    else -> "Активный звонок"
                }
            )
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setColor(Color.rgb(26, 76, 221))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder().setName(remote).setImportant(true).build()
            builder.setStyle(Notification.CallStyle.forOngoingCall(person, hangup))
        } else {
            builder.addAction(Notification.Action.Builder(R.drawable.ic_call_end, "Завершить", hangup).build())
        }
        val notification = builder.build()
        notificationManager().cancel(CALL_NOTIFICATION_ID)
        startTypedForeground(notification, callAudio = true)
    }

    private fun startTypedForeground(notification: Notification, callAudio: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val type = if (callAudio) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    (if (TvoiceRuntime.isVideoCall && TvoiceRuntime.isVideoCameraEnabled()) {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                    } else 0)
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            }
            startForeground(SERVICE_NOTIFICATION_ID, notification, type)
        } else {
            startForeground(SERVICE_NOTIFICATION_ID, notification)
        }
    }

    private fun servicePendingIntent(requestCode: Int, action: String): PendingIntent = PendingIntent.getService(
        this,
        requestCode,
        Intent(this, TvoiceCallService::class.java).setAction(action),
        immutableUpdateFlags()
    )

    private fun createNotificationChannels() {
        // Channel sound settings are immutable after first creation. Versions before
        // v4 could therefore keep Android's own ringtone even though Tvoice stopped
        // its local Ringtone. A new silent channel makes Tvoice the sole sound owner.
        notificationManager().deleteNotificationChannel("tvoice_calls_v1")
        notificationManager().deleteNotificationChannel("tvoice_calls_v2")
        notificationManager().deleteNotificationChannel("tvoice_calls_v3")
        val service = NotificationChannel(
            SERVICE_CHANNEL,
            "Работа Tvoice",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Поддерживает подключение к SIP-серверу"
            setShowBadge(false)
        }
        val calls = NotificationChannel(
            INCOMING_CALL_CHANNEL,
            "Входящие звонки",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Входящие и активные звонки Tvoice"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            // Sound and vibration are controlled by Tvoice preferences so the user
            // can configure them without leaving the app.
            enableVibration(false)
            setSound(null, null)
        }
        val activeCalls = NotificationChannel(
            ACTIVE_CALL_CHANNEL,
            "Активные звонки",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Текущий разговор Tvoice"
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        val chats = NotificationChannel(
            CHAT_CHANNEL,
            "Сообщения Tvoice",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Новые сообщения от SIP-абонентов"
            enableVibration(true)
        }
        notificationManager().createNotificationChannels(listOf(service, calls, activeCalls, chats))
    }

    private fun notificationManager(): NotificationManager = getSystemService(NotificationManager::class.java)
    private fun immutableFlags(): Int = PendingIntent.FLAG_IMMUTABLE
    private fun immutableUpdateFlags(): Int = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

    companion object {
        const val ACTION_RESTORE = "tj.tvoice.app.action.RESTORE"
        const val ACTION_START = "tj.tvoice.app.action.START"
        const val ACTION_INCOMING_SCREEN_VISIBLE = "tj.tvoice.app.action.INCOMING_SCREEN_VISIBLE"
        const val ACTION_ANSWER = "tj.tvoice.app.action.ANSWER_CALL"
        const val ACTION_DECLINE = "tj.tvoice.app.action.DECLINE"
        const val ACTION_HANGUP = "tj.tvoice.app.action.HANGUP"
        const val ACTION_SETTINGS_CHANGED = "tj.tvoice.app.action.SETTINGS_CHANGED"
        const val ACTION_VIDEO_STATE_CHANGED = "tj.tvoice.app.action.VIDEO_STATE_CHANGED"
        const val ACTION_VIDEO_ALERT_STOP = "tj.tvoice.app.action.VIDEO_ALERT_STOP"
        const val ACTION_VIDEO_DECLINE = "tj.tvoice.app.action.VIDEO_DECLINE"
        private const val EXTRA_VIDEO_CALL_ID = "video_call_id"

        const val PREF_RINGTONE_ENABLED = "ringtone_enabled"
        const val PREF_VIBRATION_ENABLED = "vibration_enabled"
        const val PREF_CALL_NOTIFICATIONS_ENABLED = "call_notifications_enabled"
        const val PREF_CHAT_NOTIFICATIONS_ENABLED = "chat_notifications_enabled"

        private const val SERVICE_CHANNEL = "tvoice_service_v1"
        const val INCOMING_CALL_CHANNEL = "tvoice_calls_v4"
        private const val ACTIVE_CALL_CHANNEL = "tvoice_active_calls_v1"
        private const val CHAT_CHANNEL = "tvoice_messages_v1"
        private const val SERVICE_NOTIFICATION_ID = 5101
        private const val CALL_NOTIFICATION_ID = 5102
        private const val CHAT_NOTIFICATION_BASE = 5200
        private const val PREFERENCES = "tvoice"
        private const val RINGBACK_PULSE_MS = 1_000
        private const val RINGBACK_CYCLE_MS = 4_000L
        private const val INCOMING_TONE_PULSE_MS = 900
        private const val INCOMING_TONE_CYCLE_MS = 3_800L
    }
}
