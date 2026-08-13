package tj.tvoice.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.Space
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat

/** Lock-screen-safe incoming call screen, launched by the native CallStyle notification. */
class IncomingCallActivity : Activity(), SipManager.Observer {
    private var remote = "Неизвестный"
    private var answerRequested = false
    private val blue: Int get() = TvoiceUi.color(this, R.color.tvoice_blue)
    private val dark: Int get() = TvoiceUi.color(this, R.color.tvoice_text_primary)
    private val muted: Int get() = TvoiceUi.color(this, R.color.tvoice_text_secondary)
    private val incomingPage: Int get() = TvoiceUi.color(this, R.color.tvoice_blue_soft)
    private val green: Int get() = TvoiceUi.color(this, R.color.tvoice_green)
    private val red: Int get() = TvoiceUi.color(this, R.color.tvoice_red)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = true
            isAppearanceLightNavigationBars = true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        TvoiceRuntime.initialize(this)
        TvoiceRuntime.addObserver(this)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        if (answerRequested || isFinishing || TvoiceRuntime.callState != CallState.IncomingReceived) return
        startService(
            Intent(this, TvoiceCallService::class.java)
                .setAction(TvoiceCallService.ACTION_INCOMING_SCREEN_VISIBLE)
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        remote = intent.getStringExtra(EXTRA_REMOTE)
            ?: TvoiceRuntime.remoteNumber.takeIf { it.isNotBlank() }
            ?: "Неизвестный"
        if (intent.action == ACTION_ANSWER) {
            answer()
            return
        }
        render()
    }

    private fun render() {
        val horizontalPadding = dp(28)
        val topPadding = dp(58)
        val bottomPadding = dp(42)
        val fallbackTopInset = statusBarHeight()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(
                horizontalPadding,
                topPadding + fallbackTopInset,
                horizontalPadding,
                bottomPadding
            )
            setBackgroundColor(incomingPage)
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val types = WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
            val system = insets.getInsets(types)
            val stable = insets.getInsetsIgnoringVisibility(types)
            view.setPadding(
                horizontalPadding + maxOf(system.left, stable.left),
                topPadding + maxOf(system.top, stable.top, fallbackTopInset),
                horizontalPadding + maxOf(system.right, stable.right),
                bottomPadding + maxOf(system.bottom, stable.bottom)
            )
            insets
        }
        root.addView(TextView(this).apply {
            text = "Tvoice"
            TvoiceUi.style(this, TvoiceUi.SCREEN_TITLE_SP, blue, TvoiceUi.semiBold())
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-1, -2))
        val avatar = TextView(this).apply {
            text = remote.take(2)
            TvoiceUi.style(this, TvoiceUi.PAGE_TITLE_SP, Color.WHITE, TvoiceUi.bold())
            gravity = Gravity.CENTER
            background = circle(blue)
        }
        root.addView(avatar, LinearLayout.LayoutParams(dp(96), dp(96)).apply { topMargin = dp(64) })
        root.addView(TextView(this).apply {
            text = remote
            TvoiceUi.style(this, TvoiceUi.CALL_NUMBER_SP, dark, TvoiceUi.bold())
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(28) })
        root.addView(TextView(this).apply {
            text = if (TvoiceRuntime.isVideoCall) {
                t("Входящий видеозвонок Tvoice", "Занги видеоии воридотии Tvoice")
            } else {
                t("Входящий вызов Tvoice", "Занги воридотии Tvoice")
            }
            TvoiceUi.style(this, TvoiceUi.SCREEN_TITLE_SP, muted)
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
        root.addView(Space(this), LinearLayout.LayoutParams(1, 0, 1f))

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        actions.addView(callAction(R.drawable.ic_call_end, red, t("Отклонить", "Рад кардан")) {
            TvoiceRuntime.hangup()
            finishAndRemoveTask()
        }, LinearLayout.LayoutParams(0, dp(124), 1f))
        actions.addView(callAction(R.drawable.ic_call, green, t("Ответить", "Ҷавоб додан")) { answer() }, LinearLayout.LayoutParams(0, dp(124), 1f))
        root.addView(actions, LinearLayout.LayoutParams(-1, dp(124)))
        setContentView(root)
        root.post { ViewCompat.requestApplyInsets(root) }
    }

    private fun answer() {
        if (answerRequested) return
        answerRequested = true
        startService(
            Intent(this, TvoiceCallService::class.java)
                .setAction(TvoiceCallService.ACTION_ANSWER)
        )
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_OPEN_CALL, true)
        )
        finish()
    }

    private fun callAction(icon: Int, color: Int, label: String, action: () -> Unit): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val image = ImageView(this@IncomingCallActivity).apply {
                setImageResource(icon)
                setColorFilter(Color.WHITE)
                setPadding(dp(20), dp(20), dp(20), dp(20))
                background = circle(color)
                setOnClickListener { action() }
            }
            addView(image, LinearLayout.LayoutParams(dp(76), dp(76)))
            addView(TextView(this@IncomingCallActivity).apply {
                text = label
                TvoiceUi.style(this, TvoiceUi.BUTTON_SP, dark, TvoiceUi.semiBold())
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(-1, dp(36)).apply { topMargin = dp(6) })
        }

    override fun onRegistration(state: RegistrationState, message: String) = Unit

    override fun onCall(state: CallState, remote: String, message: String) {
        if (state == CallState.End || state == CallState.Error || state == CallState.Released) {
            runOnUiThread { if (!isFinishing) finishAndRemoveTask() }
        }
    }

    override fun onDestroy() {
        TvoiceRuntime.removeObserver(this)
        super.onDestroy()
    }

    private fun circle(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
    private fun statusBarHeight(): Int = dp(24)
    private fun t(russian: String, tajik: String): String =
        if (getSharedPreferences("tvoice", MODE_PRIVATE).getString("language", "ru") == "tg") tajik else russian

    companion object {
        private const val ACTION_SHOW = "tj.tvoice.app.action.SHOW_INCOMING"
        private const val ACTION_ANSWER = "tj.tvoice.app.action.ANSWER"
        private const val EXTRA_REMOTE = "remote"
        const val EXTRA_OPEN_CALL = "open_call"

        fun showIntent(context: Context, remote: String): Intent = Intent(context, IncomingCallActivity::class.java)
            .setAction(ACTION_SHOW)
            .putExtra(EXTRA_REMOTE, remote)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        fun answerIntent(context: Context, remote: String): Intent = showIntent(context, remote).setAction(ACTION_ANSWER)
    }
}
