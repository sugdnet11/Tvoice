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
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings

/** Keeps SIP/UDP registration alive and exposes calls through Android's native call UI. */
class TvoiceCallService : Service(), SipManager.Observer {
    private var manualRingtone: Ringtone? = null
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
        TvoiceRuntime.initialize(this)
        TvoiceRuntime.addObserver(this)
        connectivityManager = getSystemService(ConnectivityManager::class.java)
        currentNetwork = connectivityManager.activeNetwork
        connectivityManager.registerDefaultNetworkCallback(networkCallback)
        networkCallbackRegistered = true
        updateServiceNotification("Подготовка SIP-соединения…")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> Unit
            ACTION_INCOMING_SCREEN_VISIBLE -> {
                if (TvoiceRuntime.callState == CallState.IncomingReceived) {
                    notificationManager().cancel(CALL_NOTIFICATION_ID)
                    startManualRingtone()
                }
            }
            ACTION_DECLINE -> TvoiceRuntime.hangup()
            ACTION_HANGUP -> TvoiceRuntime.hangup()
            ACTION_RESTORE, null -> TvoiceRuntime.restoreSavedAccount()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopManualRingtone()
        mainHandler.removeCallbacks(reconnectAfterNetworkChange)
        if (networkCallbackRegistered) {
            runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
            networkCallbackRegistered = false
        }
        TvoiceRuntime.removeObserver(this)
        super.onDestroy()
    }

    private fun scheduleNetworkReconnect() {
        mainHandler.removeCallbacks(reconnectAfterNetworkChange)
        mainHandler.postDelayed(reconnectAfterNetworkChange, 1_500)
    }

    override fun onRegistration(state: RegistrationState, message: String) {
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
            CallState.IncomingReceived -> {
                if (TvoiceRuntime.isMainUiVisible) {
                    notificationManager().cancel(CALL_NOTIFICATION_ID)
                    startManualRingtone()
                } else {
                    stopManualRingtone()
                    showIncomingCall(remote)
                }
            }
            CallState.Connected, CallState.StreamsRunning, CallState.Paused -> {
                stopManualRingtone()
                showOngoingCall(remote, message)
            }
            CallState.End, CallState.Error, CallState.Released -> {
                stopManualRingtone()
                notificationManager().cancel(CALL_NOTIFICATION_ID)
                updateServiceNotification("${TvoiceRuntime.activeUsername} • в сети")
            }
            else -> Unit
        }
    }

    override fun onMessage(state: MessageState, remote: String, text: String, message: String) {
        if (state != MessageState.Received || TvoiceRuntime.isMainUiVisible) return
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
        val answer = PendingIntent.getActivity(
            this,
            11,
            IncomingCallActivity.answerIntent(this, remote),
            immutableUpdateFlags()
        )
        val decline = servicePendingIntent(12, ACTION_DECLINE)
        val person = Person.Builder()
            .setName(remote)
            .setImportant(true)
            .setIcon(Icon.createWithResource(this, R.drawable.ic_account))
            .build()
        val builder = Notification.Builder(this, CALL_CHANNEL)
            .setSmallIcon(R.drawable.ic_call)
            .setContentTitle("Входящий звонок")
            .setContentText(remote)
            .setContentIntent(fullScreen)
            .setFullScreenIntent(fullScreen, true)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setColor(Color.rgb(26, 76, 221))
            .setTimeoutAfter(60_000)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setStyle(Notification.CallStyle.forIncomingCall(person, decline, answer))
        } else {
            builder.addAction(Notification.Action.Builder(R.drawable.ic_call_end, "Отклонить", decline).build())
            builder.addAction(Notification.Action.Builder(R.drawable.ic_call, "Ответить", answer).build())
        }
        notificationManager().notify(CALL_NOTIFICATION_ID, builder.build())
    }

    private fun startManualRingtone() {
        if (manualRingtone?.isPlaying == true) return
        val ringtone = runCatching {
            RingtoneManager.getRingtone(
                this,
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            )
        }.getOrNull() ?: return
        ringtone.audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) ringtone.isLooping = true
        manualRingtone = ringtone
        runCatching { ringtone.play() }
    }

    private fun stopManualRingtone() {
        manualRingtone?.let { runCatching { it.stop() } }
        manualRingtone = null
    }

    private fun showOngoingCall(remote: String, message: String) {
        val hangup = servicePendingIntent(20, ACTION_HANGUP)
        val open = PendingIntent.getActivity(
            this,
            21,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            immutableUpdateFlags()
        )
        val person = Person.Builder().setName(remote).setImportant(true).build()
        val builder = Notification.Builder(this, CALL_CHANNEL)
            .setSmallIcon(R.drawable.ic_call)
            .setContentTitle(remote)
            .setContentText(message.ifBlank { "Разговор" })
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setColor(Color.rgb(26, 76, 221))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setStyle(Notification.CallStyle.forOngoingCall(person, hangup))
        } else {
            builder.addAction(Notification.Action.Builder(R.drawable.ic_call_end, "Завершить", hangup).build())
        }
        val notification = builder.build()
        notificationManager().notify(CALL_NOTIFICATION_ID, notification)
        startTypedForeground(serviceNotification("$remote • активный звонок"), callAudio = true)
    }

    private fun startTypedForeground(notification: Notification, callAudio: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val type = if (callAudio) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
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
        val service = NotificationChannel(
            SERVICE_CHANNEL,
            "Работа Tvoice",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Поддерживает подключение к SIP-серверу"
            setShowBadge(false)
        }
        val calls = NotificationChannel(
            CALL_CHANNEL,
            "Входящие звонки",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Входящие и активные звонки Tvoice"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 450, 250, 450)
            setSound(
                Settings.System.DEFAULT_RINGTONE_URI ?: Uri.parse("content://settings/system/ringtone"),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build()
            )
        }
        val chats = NotificationChannel(
            CHAT_CHANNEL,
            "Сообщения Tvoice",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Новые сообщения от SIP-абонентов"
            enableVibration(true)
        }
        notificationManager().createNotificationChannels(listOf(service, calls, chats))
    }

    private fun notificationManager(): NotificationManager = getSystemService(NotificationManager::class.java)
    private fun immutableFlags(): Int = PendingIntent.FLAG_IMMUTABLE
    private fun immutableUpdateFlags(): Int = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

    companion object {
        const val ACTION_RESTORE = "tj.tvoice.app.action.RESTORE"
        const val ACTION_START = "tj.tvoice.app.action.START"
        const val ACTION_INCOMING_SCREEN_VISIBLE = "tj.tvoice.app.action.INCOMING_SCREEN_VISIBLE"
        const val ACTION_DECLINE = "tj.tvoice.app.action.DECLINE"
        const val ACTION_HANGUP = "tj.tvoice.app.action.HANGUP"

        private const val SERVICE_CHANNEL = "tvoice_service_v1"
        private const val CALL_CHANNEL = "tvoice_calls_v1"
        private const val CHAT_CHANNEL = "tvoice_messages_v1"
        private const val SERVICE_NOTIFICATION_ID = 5101
        private const val CALL_NOTIFICATION_ID = 5102
        private const val CHAT_NOTIFICATION_BASE = 5200
    }
}
