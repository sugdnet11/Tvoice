package tj.tvoice.app

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.provider.ContactsContract
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import org.linphone.core.Call
import org.linphone.core.RegistrationState
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity(), SipManager.Observer {
    private lateinit var sip: SipManager
    private lateinit var shell: LinearLayout
    private lateinit var content: FrameLayout
    private lateinit var bottomBar: LinearLayout
    private var ownNumber = ""
    private var pendingPassword = ""
    private var dialedNumber = ""
    private val callHistory = mutableListOf<HistoryItem>()

    private val blue = Color.rgb(26, 76, 221)
    private val dark = Color.rgb(10, 33, 74)
    private val cyan = Color.rgb(2, 194, 229)
    private val green = Color.rgb(34, 197, 94)
    private val red = Color.rgb(239, 68, 68)
    private val page = Color.rgb(247, 249, 252)
    private val line = Color.rgb(224, 230, 239)
    private val muted = Color.rgb(100, 116, 139)

    data class HistoryItem(val number: String, val direction: String, val time: String)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sip = SipManager(this, this)
        showLogin()
    }

    private fun createShell(showNavigation: Boolean = true) {
        shell = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(page)
        }
        content = FrameLayout(this)
        shell.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(6), dp(8), dp(6), dp(8))
            background = rounded(Color.WHITE, 0f, line, 1)
            elevation = dp(10).toFloat()
            visibility = if (showNavigation) View.VISIBLE else View.GONE
        }
        if (showNavigation) {
            navItem("◷", "История") { showHistory() }
            navItem("♙", "Контакты") { showContacts() }
            navItem("⌨", "Набор") { showDialer() }
            navItem("◉", "Аккаунт") { showAccount() }
        }
        shell.addView(bottomBar, LinearLayout.LayoutParams(-1, dp(76)))
        setContentView(shell)
    }

    private fun screen(scroll: Boolean = true): LinearLayout {
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(20), dp(22), dp(24))
            setBackgroundColor(page)
        }
        content.removeAllViews()
        if (scroll) {
            val scroller = ScrollView(this).apply { isFillViewport = true; addView(body) }
            content.addView(scroller, FrameLayout.LayoutParams(-1, -1))
        } else content.addView(body, FrameLayout.LayoutParams(-1, -1))
        return body
    }

    private fun showLogin() {
        createShell(false)
        val body = screen().apply { gravity = Gravity.CENTER_HORIZONTAL }
        val logo = TextView(this).apply {
            text = "T  ≋"; textSize = 34f; setTextColor(Color.WHITE); gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD; background = rounded(blue, dp(24).toFloat())
        }
        body.addView(logo, LinearLayout.LayoutParams(dp(92), dp(92)).apply { topMargin = dp(34) })
        heading(body, "Tvoice", 36, blue, 18)
        heading(body, "Добро пожаловать", 25, dark, 34)
        sub(body, "Войдите в свою учётную запись", 15, muted, 6)

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(18), dp(18), dp(18))
            background = rounded(Color.WHITE, dp(20).toFloat(), line, 1)
            elevation = dp(3).toFloat()
        }
        body.addView(card, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(28) })
        val username = modernEdit(card, "SIP-номер", "Например, 70707", false)
        val password = modernEdit(card, "Пароль", "Введите пароль", true)
        primaryButton(card, "Войти", blue, 20) {
            ownNumber = username.text.toString().trim()
            pendingPassword = password.text.toString()
            if (ownNumber.isBlank() || pendingPassword.isBlank()) toast("Введите номер и пароль")
            else ensureAudioPermissionAndLogin()
        }
        sub(body, "🔒  Сервер настроен автоматически", 13, muted, 18)
        sub(body, "185.177.2.115 • UDP", 12, Color.LTGRAY, 4)
    }

    private fun ensureAudioPermissionAndLogin() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 10)
        else register()
    }

    private fun register() {
        createShell(false)
        val body = screen().apply { gravity = Gravity.CENTER }
        heading(body, ownNumber, 32, blue, 130)
        sub(body, "Подключение к Tvoice…", 17, muted, 10)
        body.addView(ProgressBar(this), LinearLayout.LayoutParams(dp(52), dp(52)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(28) })
        try { sip.login(ownNumber, pendingPassword) }
        catch (e: Exception) { toast(e.message ?: "Ошибка регистрации"); showLogin() }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            10 -> if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) register() else toast("Для звонков нужен доступ к микрофону")
            11 -> showContacts()
        }
    }

    private fun showDialer() {
        createShell()
        val body = screen().apply { gravity = Gravity.CENTER_HORIZONTAL }
        accountHeader(body)
        val numberView = TextView(this).apply {
            text = dialedNumber.ifEmpty { "Введите номер" }
            textSize = if (dialedNumber.isEmpty()) 20f else 34f
            setTextColor(if (dialedNumber.isEmpty()) muted else dark)
            gravity = Gravity.CENTER
            setPadding(dp(12), 0, dp(12), 0)
            background = rounded(Color.WHITE, dp(18).toFloat(), line, 1)
        }
        body.addView(numberView, LinearLayout.LayoutParams(-1, dp(72)).apply { topMargin = dp(22) })
        val keys = arrayOf(
            arrayOf("1" to "", "2" to "ABC", "3" to "DEF"),
            arrayOf("4" to "GHI", "5" to "JKL", "6" to "MNO"),
            arrayOf("7" to "PQRS", "8" to "TUV", "9" to "WXYZ"),
            arrayOf("*" to "", "0" to "+", "#" to "")
        )
        keys.forEach { rowKeys ->
            val row = LinearLayout(this).apply { gravity = Gravity.CENTER }
            rowKeys.forEach { (key, letters) ->
                val keyView = TextView(this).apply {
                    text = if (letters.isEmpty()) key else "$key\n$letters"
                    textSize = if (letters.isEmpty()) 26f else 23f
                    setTextColor(dark); gravity = Gravity.CENTER; setLineSpacing(0f, .82f)
                    background = rounded(Color.WHITE, dp(35).toFloat(), line, 1)
                    elevation = dp(2).toFloat()
                    setOnClickListener {
                        dialedNumber += key
                        numberView.text = dialedNumber; numberView.textSize = 34f; numberView.setTextColor(dark)
                    }
                }
                row.addView(keyView, LinearLayout.LayoutParams(dp(78), dp(70)).apply { setMargins(dp(7), dp(6), dp(7), dp(6)) })
            }
            body.addView(row)
        }
        val actions = LinearLayout(this).apply { gravity = Gravity.CENTER }
        val erase = circleButton("⌫", Color.WHITE, dark) {
            dialedNumber = dialedNumber.dropLast(1)
            numberView.text = dialedNumber.ifEmpty { "Введите номер" }
            numberView.textSize = if (dialedNumber.isEmpty()) 20f else 34f
            numberView.setTextColor(if (dialedNumber.isEmpty()) muted else dark)
        }
        val call = circleButton("☎", cyan, Color.WHITE) {
            if (dialedNumber.isBlank()) toast("Введите номер")
            else try {
                callHistory.add(0, HistoryItem(dialedNumber, "Исходящий", now()))
                sip.call(dialedNumber)
            } catch (e: Exception) { toast(e.message ?: "Ошибка вызова") }
        }
        actions.addView(erase, LinearLayout.LayoutParams(dp(66), dp(66)).apply { rightMargin = dp(22) })
        actions.addView(call, LinearLayout.LayoutParams(dp(76), dp(76)))
        body.addView(actions, LinearLayout.LayoutParams(-1, dp(92)).apply { topMargin = dp(7) })
    }

    private fun accountHeader(body: LinearLayout) {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(13), dp(16), dp(13)); background = rounded(Color.WHITE, dp(18).toFloat(), line, 1)
        }
        val avatar = TextView(this).apply {
            text = ownNumber.take(2); textSize = 18f; setTextColor(Color.WHITE); gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD; background = rounded(blue, dp(24).toFloat())
        }
        card.addView(avatar, LinearLayout.LayoutParams(dp(48), dp(48)))
        val info = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(13), 0, 0, 0) }
        heading(info, ownNumber, 20, dark, 0)
        sub(info, "● В сети", 14, green, 3)
        card.addView(info, LinearLayout.LayoutParams(0, -2, 1f))
        body.addView(card, LinearLayout.LayoutParams(-1, -2))
    }

    private fun showHistory() {
        createShell(); val body = screen()
        heading(body, "История звонков", 27, dark, 4)
        sub(body, "Последние вызовы", 14, muted, 5)
        if (callHistory.isEmpty()) emptyState(body, "◷", "История пока пуста", "Совершённые и принятые звонки появятся здесь")
        else callHistory.forEach { item -> listCard(body, item.number, "${item.direction} • ${item.time}", if (item.direction == "Входящий") green else blue) { dialedNumber = item.number; showDialer() } }
    }

    private fun showContacts() {
        createShell(); val body = screen()
        heading(body, "Контакты", 27, dark, 4)
        sub(body, "Телефонная книга устройства", 14, muted, 5)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            emptyState(body, "♙", "Разрешите доступ к контактам", "Tvoice покажет контакты только на этом устройстве")
            primaryButton(body, "Разрешить доступ", blue, 18) { ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_CONTACTS), 11) }
            return
        }
        val contacts = loadContacts()
        if (contacts.isEmpty()) emptyState(body, "♙", "Контакты не найдены", "Добавьте контакт в телефонную книгу")
        else contacts.forEach { (name, phone) -> listCard(body, name, phone, cyan) { dialedNumber = phone.filter { it.isDigit() || it == '+' }; showDialer() } }
    }

    private fun loadContacts(): List<Pair<String, String>> {
        val result = mutableListOf<Pair<String, String>>()
        val cursor = contentResolver.query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER), null, null,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC")
        cursor?.use {
            val nameIndex = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val phoneIndex = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
            while (it.moveToNext() && result.size < 100) result += it.getString(nameIndex) to it.getString(phoneIndex)
        }
        return result.distinct()
    }

    private fun showAccount() {
        createShell(); val body = screen()
        heading(body, "Аккаунт", 27, dark, 4)
        val profile = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            setPadding(dp(20), dp(24), dp(20), dp(24)); background = rounded(Color.WHITE, dp(22).toFloat(), line, 1)
        }
        body.addView(profile, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(20) })
        val avatar = TextView(this).apply { text = ownNumber.take(2); textSize = 30f; setTextColor(Color.WHITE); gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD; background = rounded(blue, dp(38).toFloat()) }
        profile.addView(avatar, LinearLayout.LayoutParams(dp(76), dp(76)))
        heading(profile, ownNumber, 25, dark, 14); sub(profile, "● Подключено", 14, green, 5)
        section(body, "Настройки")
        settingCard(body, "Уведомления", "Входящие звонки и события", "Включены")
        settingCard(body, "Звук и устройства", "Микрофон, динамик, Bluetooth", "Авто")
        settingCard(body, "SIP-сервер", "185.177.2.115:5060", "UDP")
        section(body, "Приложение")
        settingCard(body, "Версия", "Tvoice для Android", "0.2.0")
        primaryButton(body, "Выйти из аккаунта", red, 22) { sip.logout(); ownNumber = ""; pendingPassword = ""; showLogin() }
    }

    private fun showCall(remote: String, state: String, incoming: Boolean = false) {
        createShell(false)
        val body = screen(false).apply { gravity = Gravity.CENTER_HORIZONTAL; setBackgroundColor(blue); setPadding(dp(24), dp(42), dp(24), dp(30)) }
        val avatar = TextView(this).apply { text = remote.take(2); textSize = 32f; setTextColor(Color.WHITE); gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD; background = rounded(cyan, dp(42).toFloat()) }
        body.addView(avatar, LinearLayout.LayoutParams(dp(84), dp(84)))
        heading(body, remote, 38, Color.WHITE, 22)
        sub(body, state, 17, Color.rgb(155, 235, 255), 8)
        val spacer = Space(this); body.addView(spacer, LinearLayout.LayoutParams(1, 0, 1f))
        val controls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        controls.addView(callControl("🎙", "Микрофон") { sip.toggleMute() }, LinearLayout.LayoutParams(0, dp(104), 1f))
        controls.addView(callControl("⌨", "Клавиатура") { }, LinearLayout.LayoutParams(0, dp(104), 1f))
        controls.addView(callControl("🔊", "Динамик") { sip.toggleSpeaker() }, LinearLayout.LayoutParams(0, dp(104), 1f))
        body.addView(controls, LinearLayout.LayoutParams(-1, dp(110)))
        if (incoming) primaryButton(body, "Ответить", green, 20) { sip.accept() }
        primaryButton(body, "Завершить", red, 12) { sip.hangup() }
    }

    override fun onRegistration(state: RegistrationState, message: String) = runOnUiThread {
        when (state) {
            RegistrationState.Ok -> showDialer()
            RegistrationState.Failed, RegistrationState.Cleared -> if (ownNumber.isNotEmpty()) { toast("Не удалось войти: $message"); showLogin() }
            else -> Unit
        }
    }

    override fun onCall(state: Call.State, remote: String, message: String) = runOnUiThread {
        when (state) {
            Call.State.IncomingReceived -> {
                callHistory.add(0, HistoryItem(remote, "Входящий", now()))
                showCall(remote, "Входящий вызов", true)
            }
            Call.State.OutgoingInit, Call.State.OutgoingProgress, Call.State.OutgoingRinging -> showCall(remote, "Вызов…")
            Call.State.Connected, Call.State.StreamsRunning -> showCall(remote, "Соединено")
            Call.State.End, Call.State.Error, Call.State.Released -> showDialer()
            else -> Unit
        }
    }

    private fun navItem(icon: String, label: String, action: () -> Unit) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            val i = TextView(this@MainActivity).apply { text = icon; textSize = 22f; setTextColor(blue); gravity = Gravity.CENTER }
            val l = TextView(this@MainActivity).apply { text = label; textSize = 11f; setTextColor(dark); gravity = Gravity.CENTER }
            addView(i); addView(l); setOnClickListener { action() }
        }
        bottomBar.addView(box, LinearLayout.LayoutParams(0, -1, 1f))
    }

    private fun modernEdit(parent: LinearLayout, label: String, hint: String, password: Boolean): EditText {
        sub(parent, label, 13, dark, if (parent.childCount == 0) 0 else 15)
        val field = EditText(this).apply {
            this.hint = hint; textSize = 17f; setTextColor(dark); setHintTextColor(Color.rgb(148, 163, 184))
            inputType = if (password) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_CLASS_PHONE
            setPadding(dp(16), 0, dp(16), 0); background = rounded(Color.WHITE, dp(13).toFloat(), Color.rgb(190, 201, 218), 2)
        }
        parent.addView(field, LinearLayout.LayoutParams(-1, dp(58)).apply { topMargin = dp(7) })
        return field
    }

    private fun listCard(parent: LinearLayout, title: String, detail: String, accent: Int, action: () -> Unit) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(dp(15), dp(13), dp(15), dp(13))
            background = rounded(Color.WHITE, dp(16).toFloat(), line, 1); setOnClickListener { action() }
        }
        val dot = TextView(this).apply { text = title.take(1).uppercase(); textSize = 18f; setTextColor(Color.WHITE); gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD; background = rounded(accent, dp(23).toFloat()) }
        row.addView(dot, LinearLayout.LayoutParams(dp(46), dp(46)))
        val text = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(13), 0, 0, 0) }
        heading(text, title, 17, dark, 0); sub(text, detail, 13, muted, 3)
        row.addView(text, LinearLayout.LayoutParams(0, -2, 1f))
        parent.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
    }

    private fun emptyState(parent: LinearLayout, icon: String, title: String, description: String) {
        val box = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setPadding(dp(20), dp(38), dp(20), dp(38)); background = rounded(Color.WHITE, dp(20).toFloat(), line, 1) }
        val i = TextView(this).apply { text = icon; textSize = 42f; setTextColor(blue); gravity = Gravity.CENTER }
        box.addView(i); heading(box, title, 19, dark, 17); sub(box, description, 14, muted, 7)
        parent.addView(box, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(24) })
    }

    private fun settingCard(parent: LinearLayout, title: String, detail: String, value: String) {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(dp(16), dp(14), dp(16), dp(14)); background = rounded(Color.WHITE, dp(15).toFloat(), line, 1) }
        val texts = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        heading(texts, title, 16, dark, 0); sub(texts, detail, 12, muted, 3)
        row.addView(texts, LinearLayout.LayoutParams(0, -2, 1f))
        sub(row, value, 13, blue, 0)
        parent.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(9) })
    }

    private fun section(parent: LinearLayout, text: String) { heading(parent, text, 17, dark, 24) }

    private fun primaryButton(parent: LinearLayout, text: String, color: Int, top: Int, action: (View) -> Unit): Button {
        val button = Button(this).apply {
            this.text = text; textSize = 17f; setTextColor(Color.WHITE); typeface = Typeface.DEFAULT_BOLD
            background = rounded(color, dp(15).toFloat()); stateListAnimator = null; setOnClickListener(action)
        }
        parent.addView(button, LinearLayout.LayoutParams(-1, dp(58)).apply { topMargin = dp(top) })
        return button
    }

    private fun circleButton(text: String, backgroundColor: Int, textColor: Int, action: () -> Unit) = TextView(this).apply {
        this.text = text; textSize = 27f; setTextColor(textColor); gravity = Gravity.CENTER; background = rounded(backgroundColor, dp(38).toFloat(), line, 1); elevation = dp(3).toFloat(); setOnClickListener { action() }
    }

    private fun callControl(icon: String, label: String, action: () -> Unit) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
        val i = TextView(this@MainActivity).apply { text = icon; textSize = 26f; gravity = Gravity.CENTER; setTextColor(Color.WHITE); background = rounded(Color.argb(45, 255, 255, 255), dp(30).toFloat()); setOnClickListener { action() } }
        addView(i, LinearLayout.LayoutParams(dp(60), dp(60)))
        val l = TextView(this@MainActivity).apply { text = label; textSize = 12f; gravity = Gravity.CENTER; setTextColor(Color.WHITE) }
        addView(l, LinearLayout.LayoutParams(-1, dp(32)))
    }

    private fun heading(parent: LinearLayout, text: String, size: Int, color: Int, top: Int): TextView {
        val v = TextView(this).apply { this.text = text; textSize = size.toFloat(); setTextColor(color); typeface = Typeface.DEFAULT_BOLD; gravity = if (parent.gravity == Gravity.CENTER_HORIZONTAL || parent.gravity == Gravity.CENTER) Gravity.CENTER else Gravity.START }
        parent.addView(v, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }); return v
    }

    private fun sub(parent: LinearLayout, text: String, size: Int, color: Int, top: Int): TextView {
        val v = TextView(this).apply { this.text = text; textSize = size.toFloat(); setTextColor(color); gravity = if (parent.gravity == Gravity.CENTER_HORIZONTAL || parent.gravity == Gravity.CENTER) Gravity.CENTER else Gravity.START }
        parent.addView(v, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }); return v
    }

    private fun rounded(color: Int, radius: Float, strokeColor: Int? = null, strokeWidth: Int = 0) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE; setColor(color); cornerRadius = radius
        if (strokeColor != null && strokeWidth > 0) setStroke(dp(strokeWidth), strokeColor)
    }

    private fun now() = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date())
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_LONG).show()
    override fun onDestroy() { sip.destroy(); super.onDestroy() }
}
