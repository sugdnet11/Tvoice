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

/** Lock-screen-safe incoming call screen, launched by the native CallStyle notification. */
class IncomingCallActivity : Activity(), SipManager.Observer {
    private var remote = "Неизвестный"
    private val blue = Color.rgb(26, 76, 221)
    private val green = Color.rgb(34, 197, 94)
    private val red = Color.rgb(239, 68, 68)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(58), dp(28), dp(42))
            setBackgroundColor(blue)
        }
        val avatar = TextView(this).apply {
            text = remote.take(2)
            textSize = 34f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            background = circle(Color.rgb(2, 194, 229))
        }
        root.addView(avatar, LinearLayout.LayoutParams(dp(104), dp(104)))
        root.addView(TextView(this).apply {
            text = remote
            textSize = 38f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(28) })
        root.addView(TextView(this).apply {
            text = "Входящий вызов Tvoice"
            textSize = 17f
            setTextColor(Color.rgb(176, 231, 255))
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
        root.addView(Space(this), LinearLayout.LayoutParams(1, 0, 1f))

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        actions.addView(callAction(R.drawable.ic_call_end, red, "Отклонить") {
            TvoiceRuntime.hangup()
            finishAndRemoveTask()
        }, LinearLayout.LayoutParams(0, dp(124), 1f))
        actions.addView(callAction(R.drawable.ic_call, green, "Ответить") { answer() }, LinearLayout.LayoutParams(0, dp(124), 1f))
        root.addView(actions, LinearLayout.LayoutParams(-1, dp(124)))
        setContentView(root)
    }

    private fun answer() {
        TvoiceRuntime.accept()
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
                textSize = 14f
                setTextColor(Color.WHITE)
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
