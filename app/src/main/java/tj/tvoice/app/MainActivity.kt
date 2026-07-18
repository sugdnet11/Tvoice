package tj.tvoice.app

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import org.linphone.core.Call
import org.linphone.core.RegistrationState

class MainActivity : AppCompatActivity(), SipManager.Observer {
    private lateinit var sip: SipManager
    private lateinit var root: LinearLayout
    private var ownNumber = ""
    private var pendingPassword = ""
    private val blue = Color.rgb(18, 70, 216)
    private val dark = Color.rgb(8, 35, 84)
    private val cyan = Color.rgb(5, 199, 232)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sip = SipManager(this, this)
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(28), dp(24), dp(20))
            setBackgroundColor(Color.WHITE)
        }
        setContentView(ScrollView(this).apply { addView(root) })
        showLogin()
    }

    private fun showLogin() {
        root.removeAllViews()
        title("Tvoice", 42, blue)
        label("Добро пожаловать", 28, blue, dp(36))
        label("Войдите в свою учётную запись", 16, Color.DKGRAY, dp(6))
        val username = edit("SIP-номер", InputType.TYPE_CLASS_PHONE, dp(34))
        val password = edit("Пароль", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD, dp(12))
        button("Войти", blue, dp(20)) {
            ownNumber = username.text.toString().trim()
            pendingPassword = password.text.toString()
            if (ownNumber.isBlank() || pendingPassword.isBlank()) toast("Введите номер и пароль")
            else ensureAudioPermissionAndLogin()
        }
        label("Сервер настроен автоматически", 13, Color.GRAY, dp(18))
    }

    private fun ensureAudioPermissionAndLogin() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 10)
        } else register()
    }

    private fun register() {
        try {
            showConnecting()
            sip.login(ownNumber, pendingPassword)
        } catch (e: Exception) {
            toast(e.message ?: "Ошибка регистрации")
            showLogin()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 10 && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) register()
        else toast("Для звонков нужен доступ к микрофону")
    }

    private fun showConnecting() {
        root.removeAllViews()
        title(ownNumber, 28, blue)
        label("Подключение…", 16, Color.GRAY, dp(8))
        ProgressBar(this).also { root.addView(it, lp(dp(48), dp(48), dp(34))) }
    }

    private fun showDialer(status: String = "В сети") {
        root.removeAllViews()
        title(ownNumber, 28, blue)
        label("● $status", 16, Color.rgb(34, 197, 94), dp(4))
        val number = TextView(this).apply {
            textSize = 36f; setTextColor(dark); gravity = Gravity.CENTER
            setPadding(0, dp(28), 0, dp(18))
        }
        root.addView(number, lp(-1, dp(92)))
        val keys = arrayOf(arrayOf("1","2","3"), arrayOf("4","5","6"), arrayOf("7","8","9"), arrayOf("*","0","#"))
        keys.forEach { rowKeys ->
            val row = LinearLayout(this).apply { gravity = Gravity.CENTER }
            rowKeys.forEach { key ->
                val b = Button(this).apply {
                    text = key; textSize = 25f; setTextColor(dark)
                    setOnClickListener { number.text = number.text.toString() + key }
                }
                row.addView(b, LinearLayout.LayoutParams(dp(84), dp(68)).apply { setMargins(dp(5), dp(4), dp(5), dp(4)) })
            }
            root.addView(row)
        }
        button("Вызов", cyan, dp(16)) {
            if (number.text.isBlank()) toast("Введите номер") else try { sip.call(number.text.toString()) } catch (e: Exception) { toast(e.message ?: "Ошибка вызова") }
        }
        button("⌫", Color.LTGRAY, dp(8)) { number.text = number.text.dropLast(1) }
    }

    private fun showCall(remote: String, state: String, incoming: Boolean = false) {
        root.removeAllViews()
        root.setBackgroundColor(blue)
        title(remote, 38, Color.WHITE)
        label(state, 18, cyan, dp(12))
        if (incoming) button("Ответить", Color.rgb(34, 197, 94), dp(40)) { sip.accept() }
        button("Микрофон", Color.WHITE, dp(24)) { muted -> muted.isSelected = sip.toggleMute() }
        button("Динамик", Color.WHITE, dp(8)) { speaker -> speaker.isSelected = sip.toggleSpeaker() }
        button("Завершить", Color.rgb(239, 68, 68), dp(26)) { sip.hangup() }
    }

    override fun onRegistration(state: RegistrationState, message: String) = runOnUiThread {
        when (state) {
            RegistrationState.Ok -> showDialer()
            RegistrationState.Failed, RegistrationState.Cleared -> { toast("Не удалось войти: $message"); showLogin() }
            else -> Unit
        }
    }

    override fun onCall(state: Call.State, remote: String, message: String) = runOnUiThread {
        when (state) {
            Call.State.IncomingReceived -> showCall(remote, "Входящий вызов", true)
            Call.State.OutgoingInit, Call.State.OutgoingProgress, Call.State.OutgoingRinging -> showCall(remote, "Вызов…")
            Call.State.Connected, Call.State.StreamsRunning -> showCall(remote, "Соединено")
            Call.State.End, Call.State.Error, Call.State.Released -> { root.setBackgroundColor(Color.WHITE); showDialer() }
            else -> Unit
        }
    }

    private fun title(text: String, size: Int, color: Int) = label(text, size, color, 0, true)
    private fun label(text: String, size: Int, color: Int, top: Int, bold: Boolean = false): TextView {
        val v = TextView(this).apply {
            this.text = text; textSize = size.toFloat(); setTextColor(color); gravity = Gravity.CENTER
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        root.addView(v, LinearLayout.LayoutParams(-1, -2).apply { topMargin = top })
        return v
    }
    private fun edit(hint: String, input: Int, top: Int): EditText {
        val v = EditText(this).apply { this.hint = hint; inputType = input; textSize = 18f; setPadding(dp(16), 0, dp(16), 0) }
        root.addView(v, LinearLayout.LayoutParams(-1, dp(64)).apply { topMargin = top })
        return v
    }
    private fun button(text: String, color: Int, top: Int, action: (View) -> Unit): Button {
        val v = Button(this).apply { this.text = text; textSize = 18f; setTextColor(if (color == Color.WHITE || color == Color.LTGRAY) dark else Color.WHITE); setBackgroundColor(color); setOnClickListener(action) }
        root.addView(v, LinearLayout.LayoutParams(-1, dp(58)).apply { topMargin = top })
        return v
    }
    private fun lp(w: Int, h: Int, top: Int = 0) = LinearLayout.LayoutParams(w, h).apply { topMargin = top }
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_LONG).show()
    override fun onDestroy() { sip.destroy(); super.onDestroy() }
}
