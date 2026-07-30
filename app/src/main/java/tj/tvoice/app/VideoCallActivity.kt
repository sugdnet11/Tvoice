package tj.tvoice.app

import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Rational
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import io.livekit.android.LiveKit
import io.livekit.android.RoomOptions
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.renderer.SurfaceViewRenderer
import io.livekit.android.room.Room
import io.livekit.android.room.track.LocalVideoTrack
import io.livekit.android.room.track.LocalVideoTrackOptions
import io.livekit.android.room.track.Track
import io.livekit.android.room.track.VideoTrack
import io.livekit.android.room.track.VideoCaptureParameter
import kotlinx.coroutines.launch
import livekit.org.webrtc.RendererCommon

/** Portrait, messenger-style video call powered by the dedicated LiveKit server. */
class VideoCallActivity : AppCompatActivity(), ChatClient.Observer {
    private lateinit var root: FrameLayout
    private lateinit var remoteRenderer: SurfaceViewRenderer
    private lateinit var localRenderer: SurfaceViewRenderer
    private lateinit var statusView: TextView
    private lateinit var controls: LinearLayout
    private lateinit var answerButton: ImageView
    private lateinit var room: Room
    private val handler = Handler(Looper.getMainLooper())

    private var callId = ""
    private var peerNumber = ""
    private var peerName = ""
    private var incoming = false
    private var connected = false
    private var callStartedAt = 0L
    private var microphoneEnabled = true
    private var cameraEnabled = true
    private var speakerEnabled = true
    private var ending = false
    private var outgoingTone: ToneGenerator? = null
    private var outgoingTonePlaying = false

    private val outgoingTonePulse = object : Runnable {
        override fun run() {
            if (!outgoingTonePlaying || connected || ending) return
            releaseOutgoingTone()
            val tone = runCatching {
                ToneGenerator(AudioManager.STREAM_VOICE_CALL, 68)
            }.getOrNull()
            outgoingTone = tone
            runCatching { tone?.startTone(ToneGenerator.TONE_SUP_RINGTONE, 1_000) }
            handler.postDelayed(this, 4_000)
        }
    }

    private val timer = object : Runnable {
        override fun run() {
            if (!connected) return
            val seconds = ((System.currentTimeMillis() - callStartedAt) / 1000).coerceAtLeast(0)
            statusView.text = "%02d:%02d".format(seconds / 60, seconds % 60)
            handler.postDelayed(this, 1_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.BLACK
        callId = intent.getStringExtra(EXTRA_CALL_ID).orEmpty()
        peerNumber = intent.getStringExtra(EXTRA_PEER_NUMBER).orEmpty()
        peerName = intent.getStringExtra(EXTRA_PEER_NAME).orEmpty().ifBlank { peerNumber }
        incoming = intent.getBooleanExtra(EXTRA_INCOMING, false)
        if (callId.isBlank() || peerNumber.isBlank()) {
            finish()
            return
        }

        ChatClient.initialize(this)
        ChatClient.addObserver(this)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = enterPipAndOpenApp()
        })
        buildUi()
        configurePictureInPicture()
        room = LiveKit.create(
            applicationContext,
            RoomOptions(
                adaptiveStream = true,
                dynacast = true,
                videoTrackCaptureDefaults = LocalVideoTrackOptions(
                    captureParams = VideoCaptureParameter(
                        width = 720,
                        // A 3:4 portrait frame matches phone camera sensors much
                        // better than forced 9:16, avoiding the zoomed/cropped face
                        // seen on the remote device while remaining vertical.
                        height = 960,
                        maxFps = 24,
                        adaptOutputToDimensions = true
                    )
                )
            )
        )
        room.initVideoRenderer(remoteRenderer)
        room.initVideoRenderer(localRenderer)
        configureSpeaker(true)

        if (incoming) {
            statusView.text = "Входящий видеозвонок"
            answerButton.visibility = View.VISIBLE
            startService(
                Intent(this, TvoiceCallService::class.java)
                    .setAction(TvoiceCallService.ACTION_INCOMING_SCREEN_VISIBLE)
            )
        } else {
            startOutgoingTone()
            credentialsFromIntent()?.let(::connect) ?: finish()
        }
    }

    private fun buildUi() {
        val blue = Color.rgb(28, 78, 220)
        root = FrameLayout(this).apply { setBackgroundColor(Color.rgb(20, 25, 34)) }
        remoteRenderer = SurfaceViewRenderer(this).apply {
            setEnableHardwareScaler(true)
            // Preserve the portrait frame ratio. FILL cropped a landscape camera
            // frame so aggressively that it looked stretched on tall displays.
            setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        }
        root.addView(remoteRenderer, FrameLayout.LayoutParams(-1, -1))

        val shade = View(this).apply {
            background = android.graphics.drawable.GradientDrawable(
                android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(0xB8000000.toInt(), Color.TRANSPARENT, 0x85000000.toInt())
            )
        }
        root.addView(shade, FrameLayout.LayoutParams(-1, -1))

        val top = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(64), dp(28), dp(64), dp(16))
        }
        top.addView(text("🔒 Сквозное шифрование", 11f, 0xFFD6D9E0.toInt()))
        top.addView(text(peerName, 22f, Color.WHITE, Typeface.BOLD).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, dp(4))
        })
        statusView = text(if (incoming) "Входящий видеозвонок" else "Вызов…", 14f, Color.WHITE).apply {
            gravity = Gravity.CENTER
        }
        top.addView(statusView)
        root.addView(top, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))

        localRenderer = SurfaceViewRenderer(this).apply {
            setEnableHardwareScaler(true)
            setZOrderMediaOverlay(true)
            setMirror(true)
            setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
            elevation = dp(8).toFloat()
            clipToOutline = true
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    outline.setRoundRect(0, 0, view.width, view.height, dp(16).toFloat())
                }
            }
            installDraggablePreview(this)
        }
        root.addView(localRenderer, FrameLayout.LayoutParams(dp(112), dp(154), Gravity.TOP or Gravity.END).apply {
            topMargin = dp(92)
            rightMargin = dp(14)
        })

        val minimize = iconButton(R.drawable.ic_minimize, 0x66000000, "Свернуть") {
            enterPipAndOpenApp()
        }
        root.addView(minimize, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP or Gravity.START).apply {
            topMargin = dp(26)
            leftMargin = dp(12)
        })

        controls = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(10), dp(12), dp(10), dp(24))
        }
        val switchCamera = iconButton(R.drawable.ic_switch_camera, 0xFF1C4EDC.toInt(), "Сменить камеру") {
            val track = room.localParticipant.getTrackPublication(Track.Source.CAMERA)?.track as? LocalVideoTrack
            runCatching { track?.switchCamera() }
        }.apply { clearColorFilter() }
        controls.addView(switchCamera)
        controls.addView(iconButton(R.drawable.ic_videocam, 0x66000000, "Камера") { button ->
            cameraEnabled = !cameraEnabled
            lifecycleScope.launch { room.localParticipant.setCameraEnabled(cameraEnabled) }
            button.setImageResource(if (cameraEnabled) R.drawable.ic_videocam else R.drawable.ic_videocam_off)
            localRenderer.visibility = if (cameraEnabled) View.VISIBLE else View.INVISIBLE
        })
        controls.addView(iconButton(R.drawable.ic_call_end, 0xFFE62D43.toInt(), "Завершить") {
            endCall(true)
        }, LinearLayout.LayoutParams(dp(64), dp(64)).apply { setMargins(dp(9), 0, dp(9), 0) })
        controls.addView(iconButton(R.drawable.ic_speaker, 0x66000000, "Динамик") { button ->
            speakerEnabled = !speakerEnabled
            configureSpeaker(speakerEnabled)
            button.setImageResource(if (speakerEnabled) R.drawable.ic_speaker else R.drawable.ic_speaker_off)
        })
        controls.addView(iconButton(R.drawable.ic_mic, 0x66000000, "Микрофон") { button ->
            microphoneEnabled = !microphoneEnabled
            lifecycleScope.launch { room.localParticipant.setMicrophoneEnabled(microphoneEnabled) }
            button.setImageResource(if (microphoneEnabled) R.drawable.ic_mic else R.drawable.ic_mic_off)
        })
        root.addView(controls, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))

        answerButton = iconButton(R.drawable.ic_call, blue, "Ответить") {
            stopVideoAlerts()
            answerButton.isEnabled = false
            statusView.text = "Соединение…"
            ChatClient.answerVideoCall(callId) { result ->
                result.onSuccess(::connect).onFailure { error ->
                    toast(error.message ?: "Не удалось принять видеозвонок")
                    endCall(false)
                }
            }
        }
        root.addView(answerButton, FrameLayout.LayoutParams(dp(68), dp(68), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
            bottomMargin = dp(112)
        })
        setContentView(root)
    }

    private fun connect(credentials: ChatClient.VideoCallCredentials) {
        answerButton.visibility = View.GONE
        statusView.text = "Соединение…"
        lifecycleScope.launch {
            launch {
                room.events.collect { event ->
                    when (event) {
                        is RoomEvent.TrackSubscribed -> if (event.track is VideoTrack) {
                            attachRemote(event.track as VideoTrack)
                        }
                        is RoomEvent.ParticipantConnected -> markConnected()
                        is RoomEvent.ParticipantDisconnected -> if (!ending) {
                            toast("Видеозвонок завершён")
                            endCall(false)
                        }
                        is RoomEvent.Disconnected -> if (!ending) {
                            toast("Соединение с видеосервером завершено")
                            endCall(false)
                        }
                        else -> Unit
                    }
                }
            }
            runCatching {
                room.connect(credentials.url, credentials.token)
                room.localParticipant.setMicrophoneEnabled(true)
                room.localParticipant.setCameraEnabled(true)
                attachLocalPreview()
                val remoteTrack = room.remoteParticipants.values.firstOrNull()
                    ?.getTrackPublication(Track.Source.CAMERA)?.track as? VideoTrack
                if (remoteTrack != null) attachRemote(remoteTrack)
                if (room.remoteParticipants.isNotEmpty()) markConnected()
                else statusView.text = "Вызов…"
            }.onFailure { error ->
                toast("Видео: ${error.message ?: "ошибка соединения"}")
                endCall(true)
            }
        }
    }

    private fun attachRemote(track: VideoTrack) {
        track.addRenderer(remoteRenderer)
        markConnected()
    }

    private fun markConnected() {
        if (connected) return
        connected = true
        stopOutgoingTone()
        callStartedAt = System.currentTimeMillis()
        handler.removeCallbacks(timer)
        handler.post(timer)
    }

    override fun onVideoCallAnswered(callId: String) {
        if (this.callId == callId && !connected) {
            stopOutgoingTone()
            statusView.text = "Соединение…"
        }
    }

    override fun onVideoCallEnded(callId: String, reason: String) {
        if (this.callId != callId) return
        toast(if (reason == "rejected") "Видеозвонок отклонён" else "Видеозвонок завершён")
        endCall(false)
    }

    private fun endCall(notifyPeer: Boolean) {
        if (ending) return
        ending = true
        stopOutgoingTone()
        handler.removeCallbacks(timer)
        stopVideoAlerts()
        if (notifyPeer) ChatClient.endVideoCall(callId)
        if (::room.isInitialized) room.disconnect()
        finishAndRemoveTask()
    }

    private fun stopVideoAlerts() {
        startService(Intent(this, TvoiceCallService::class.java).setAction(TvoiceCallService.ACTION_VIDEO_ALERT_STOP))
    }

    private fun attachLocalPreview(attempt: Int = 0) {
        val track = room.localParticipant
            .getTrackPublication(Track.Source.CAMERA)?.track as? LocalVideoTrack
        if (track != null) {
            track.addRenderer(localRenderer)
        } else if (attempt < 20 && !ending) {
            handler.postDelayed({ attachLocalPreview(attempt + 1) }, 100)
        }
    }

    private fun startOutgoingTone() {
        if (outgoingTonePlaying) return
        outgoingTonePlaying = true
        handler.removeCallbacks(outgoingTonePulse)
        handler.post(outgoingTonePulse)
    }

    private fun stopOutgoingTone() {
        outgoingTonePlaying = false
        handler.removeCallbacks(outgoingTonePulse)
        releaseOutgoingTone()
    }

    private fun releaseOutgoingTone() {
        runCatching { outgoingTone?.stopTone() }
        runCatching { outgoingTone?.release() }
        outgoingTone = null
    }

    @Suppress("DEPRECATION")
    private fun configureSpeaker(enabled: Boolean) {
        getSystemService(AudioManager::class.java).apply {
            mode = AudioManager.MODE_IN_COMMUNICATION
            isSpeakerphoneOn = enabled
        }
    }

    private fun enterPipAndOpenApp() {
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            toast("Телефон не поддерживает плавающее видео")
            return
        }
        val entered = enterPictureInPictureMode(pictureInPictureParams(autoEnter = false))
        if (!entered) toast("Не удалось свернуть видеозвонок")
    }

    private fun configurePictureInPicture() {
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return
        setPictureInPictureParams(pictureInPictureParams(autoEnter = true))
    }

    private fun pictureInPictureParams(autoEnter: Boolean): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(9, 16))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoEnter)
        }
        return builder.build()
    }

    private fun installDraggablePreview(view: View) {
        var offsetX = 0f
        var offsetY = 0f
        var moved = false
        view.setOnTouchListener { touched, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    offsetX = touched.x - event.rawX
                    offsetY = touched.y - event.rawY
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val maxX = (root.width - touched.width).coerceAtLeast(0).toFloat()
                    val maxY = (root.height - touched.height).coerceAtLeast(0).toFloat()
                    val nextX = (event.rawX + offsetX).coerceIn(0f, maxX)
                    val nextY = (event.rawY + offsetY).coerceIn(0f, maxY)
                    moved = moved || kotlin.math.abs(nextX - touched.x) > dp(3) ||
                        kotlin.math.abs(nextY - touched.y) > dp(3)
                    touched.x = nextX
                    touched.y = nextY
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) touched.performClick()
                    true
                }
                MotionEvent.ACTION_CANCEL -> true
                else -> false
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode)
        controls.visibility = if (isInPictureInPictureMode) View.GONE else View.VISIBLE
        localRenderer.visibility = if (isInPictureInPictureMode || !cameraEnabled) View.INVISIBLE else View.VISIBLE
    }

    override fun onDestroy() {
        ChatClient.removeObserver(this)
        handler.removeCallbacks(timer)
        stopOutgoingTone()
        if (!isChangingConfigurations && !ending && isFinishing) endCall(true)
        super.onDestroy()
    }

    private fun credentialsFromIntent(): ChatClient.VideoCallCredentials? {
        val url = intent.getStringExtra(EXTRA_URL).orEmpty()
        val token = intent.getStringExtra(EXTRA_TOKEN).orEmpty()
        val roomName = intent.getStringExtra(EXTRA_ROOM).orEmpty()
        if (url.isBlank() || token.isBlank() || roomName.isBlank()) return null
        return ChatClient.VideoCallCredentials(callId, roomName, url, token, peerNumber, peerName)
    }

    private fun iconButton(
        icon: Int,
        color: Int,
        description: String,
        click: (ImageView) -> Unit
    ): ImageView = ImageView(this).apply {
        setImageResource(icon)
        setColorFilter(Color.WHITE)
        setPadding(dp(14), dp(14), dp(14), dp(14))
        background = TvoiceUi.rounded(this@VideoCallActivity, color, 32)
        contentDescription = description
        setOnClickListener { click(this) }
    }

    private fun text(value: String, size: Float, color: Int, style: Int = Typeface.NORMAL) =
        TextView(this).apply {
            text = value
            textSize = size
            setTextColor(color)
            typeface = Typeface.create("sans-serif", style)
            includeFontPadding = false
        }

    private fun toast(value: String) = Toast.makeText(this, value, Toast.LENGTH_SHORT).show()

    companion object {
        private const val EXTRA_CALL_ID = "video_call_id"
        private const val EXTRA_PEER_NUMBER = "video_peer_number"
        private const val EXTRA_PEER_NAME = "video_peer_name"
        private const val EXTRA_INCOMING = "video_incoming"
        private const val EXTRA_URL = "video_url"
        private const val EXTRA_TOKEN = "video_token"
        private const val EXTRA_ROOM = "video_room"

        fun outgoingIntent(context: Context, credentials: ChatClient.VideoCallCredentials) =
            Intent(context, VideoCallActivity::class.java)
                .putExtra(EXTRA_CALL_ID, credentials.callId)
                .putExtra(EXTRA_PEER_NUMBER, credentials.peerNumber)
                .putExtra(EXTRA_PEER_NAME, credentials.peerName)
                .putExtra(EXTRA_URL, credentials.url)
                .putExtra(EXTRA_TOKEN, credentials.token)
                .putExtra(EXTRA_ROOM, credentials.room)

        fun incomingIntent(context: Context, invite: ChatClient.VideoCallInvite) =
            Intent(context, VideoCallActivity::class.java)
                .putExtra(EXTRA_CALL_ID, invite.callId)
                .putExtra(EXTRA_PEER_NUMBER, invite.peerNumber)
                .putExtra(EXTRA_PEER_NAME, invite.peerName)
                .putExtra(EXTRA_INCOMING, true)
    }
}
