package tj.tvoice.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

class FlutterSipService : Service() {
    override fun onCreate() {
        super.onCreate()
        ensureChannels(this)
        FlutterSipRuntime.initialize(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(ONGOING_ID, ongoingNotification(this, "SIP подключается…"))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val ONGOING_CHANNEL = "tvoice_sip_status"
        private const val INCOMING_CHANNEL = "tvoice_incoming_calls"
        private const val ONGOING_ID = 17301
        private const val INCOMING_ID = 17302

        fun updateStatus(context: Context, text: String) {
            ensureChannels(context)
            NotificationManagerCompat.from(context).notify(
                ONGOING_ID,
                ongoingNotification(context, text),
            )
        }

        fun showIncoming(context: Context, remote: String) {
            ensureChannels(context)
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                17302,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(context, INCOMING_CHANNEL)
                .setSmallIcon(android.R.drawable.sym_action_call)
                .setContentTitle("Входящий звонок Tvoice")
                .setContentText(remote)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setOngoing(true)
                .setAutoCancel(false)
                .setContentIntent(pendingIntent)
                .setFullScreenIntent(pendingIntent, true)
                .build()
            NotificationManagerCompat.from(context).notify(INCOMING_ID, notification)
        }

        fun cancelIncoming(context: Context) {
            NotificationManagerCompat.from(context).cancel(INCOMING_ID)
        }

        private fun ongoingNotification(context: Context, text: String): Notification {
            val pendingIntent = PendingIntent.getActivity(
                context,
                17301,
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, ONGOING_CHANNEL)
                .setSmallIcon(android.R.drawable.sym_action_call)
                .setContentTitle("Tvoice")
                .setContentText(text)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setContentIntent(pendingIntent)
                .build()
        }

        private fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    ONGOING_CHANNEL,
                    "Подключение Tvoice",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
            manager.createNotificationChannel(
                NotificationChannel(
                    INCOMING_CHANNEL,
                    "Входящие звонки Tvoice",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Уведомления о входящих SIP-звонках"
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setSound(null, null)
                },
            )
        }
    }
}
