package tj.tvoice.app

import android.Manifest
import android.app.AlertDialog
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.net.Uri
import android.provider.ContactsContract
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity(), SipManager.Observer {
    private val sip get() = TvoiceRuntime
    private lateinit var rootContainer: FrameLayout
    private lateinit var shell: LinearLayout
    private lateinit var content: FrameLayout
    private lateinit var bottomBar: LinearLayout
    private var currentScroller: ScrollView? = null
    private var ownNumber = ""
    private var pendingPassword = ""
    private var dialedNumber = ""
    private val accountNumbers = mutableListOf<String>()
    private var addingAccount = false
    private var pendingAddedNumber = ""
    private var profileUri: Uri? = null
    private var profileImage: ImageView? = null
    private val callHistory = mutableListOf<HistoryItem>()
    private var homePage = HomePage.Calls
    private var currentChatPeer: String? = null
    private var connectedAtMillis: Long? = null
    private var activeHistoryItem: HistoryItem? = null

    private val blue = Color.rgb(26, 76, 221)
    private val dark: Int get() = if (isDarkTheme) Color.rgb(241, 245, 249) else Color.rgb(10, 33, 74)
    private val cyan = Color.rgb(2, 194, 229)
    private val green = Color.rgb(34, 197, 94)
    private val red = Color.rgb(239, 68, 68)
    private val page: Int get() = if (isDarkTheme) Color.rgb(11, 18, 32) else Color.rgb(247, 249, 252)
    private val surface: Int get() = if (isDarkTheme) Color.rgb(25, 36, 55) else Color.WHITE
    private val incomingPage = Color.rgb(239, 245, 255)
    private val callPageTop: Int get() = if (isDarkTheme) Color.rgb(20, 36, 61) else Color.rgb(229, 239, 255)
    private val callPageBottom: Int get() = if (isDarkTheme) Color.rgb(11, 24, 43) else Color.rgb(248, 251, 255)
    private val line: Int get() = if (isDarkTheme) Color.rgb(51, 65, 85) else Color.rgb(224, 230, 239)
    private val muted: Int get() = if (isDarkTheme) Color.rgb(148, 163, 184) else Color.rgb(100, 116, 139)

    private val preferences get() = getSharedPreferences("tvoice", MODE_PRIVATE)
    private val isDarkTheme: Boolean get() = preferences.getString("theme", "light") == "dark"
    private val isTajik: Boolean get() = preferences.getString("language", "ru") == "tg"

    private enum class HomePage { Contacts, Calls, Chat }

    data class HistoryItem(
        val number: String,
        val direction: String,
        val time: String,
        var durationSeconds: Long = 0
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        val savedTheme = getSharedPreferences("tvoice", MODE_PRIVATE).getString("theme", "light")
        AppCompatDelegate.setDefaultNightMode(
            if (savedTheme == "dark") AppCompatDelegate.MODE_NIGHT_YES else AppCompatDelegate.MODE_NIGHT_NO
        )
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        TvoiceRuntime.initialize(this)
        TvoiceRuntime.addObserver(this)
        applySystemTheme()
        profileUri = preferences.getString("profile_uri", null)?.let(Uri::parse)
        loadCallHistory()
        renderRuntimeState()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        renderRuntimeState()
    }

    private fun renderRuntimeState() {
        ownNumber = TvoiceRuntime.activeUsername.ifBlank { TvoiceRuntime.savedUsername().orEmpty() }
        when (TvoiceRuntime.callState) {
            CallState.IncomingReceived -> showIncomingCall(TvoiceRuntime.remoteNumber)
            CallState.OutgoingInit, CallState.OutgoingProgress, CallState.OutgoingRinging ->
                showCall(TvoiceRuntime.remoteNumber, t("Вызов…", "Занг…"))
            CallState.Connected, CallState.StreamsRunning -> showCall(TvoiceRuntime.remoteNumber, t("Соединено", "Пайваст"))
            CallState.Paused -> showCall(TvoiceRuntime.remoteNumber, t("Удержание", "Нигоҳдорӣ"))
            else -> when (TvoiceRuntime.registrationState) {
                RegistrationState.Ok -> intent.getStringExtra(EXTRA_OPEN_CHAT)?.let(::showConversation) ?: showCalls()
                RegistrationState.Progress -> showConnecting()
                else -> if (ownNumber.isNotBlank()) {
                    startSipService(restore = true)
                    if (TvoiceRuntime.restoreSavedAccount()) showConnecting() else showLogin()
                } else showLogin()
            }
        }
    }

    override fun onStart() {
        super.onStart()
        TvoiceRuntime.setMainUiVisible(true)
        when (TvoiceRuntime.callState) {
            CallState.IncomingReceived,
            CallState.OutgoingInit,
            CallState.OutgoingProgress,
            CallState.OutgoingRinging,
            CallState.Connected,
            CallState.StreamsRunning,
            CallState.Paused -> renderRuntimeState()
            else -> Unit
        }
    }

    override fun onStop() {
        TvoiceRuntime.setMainUiVisible(false)
        super.onStop()
    }

    private fun createShell(showNavigation: Boolean = true) {
        val fallbackTopInset = statusBarHeight()
        rootContainer = FrameLayout(this).apply {
            setBackgroundColor(page)
            // EMUI/Huawei can deliver the first WindowInsets event late (or not at all
            // when the content view is replaced). Keep the header below the status bar
            // from the very first frame and replace this fallback with real insets below.
            setPadding(0, fallbackTopInset, 0, 0)
        }
        ViewCompat.setOnApplyWindowInsetsListener(rootContainer) { view, insets ->
            val types = WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
            val system = insets.getInsets(types)
            val stable = insets.getInsetsIgnoringVisibility(types)
            val keyboard = insets.getInsets(WindowInsetsCompat.Type.ime())
            view.setPadding(
                maxOf(system.left, stable.left),
                maxOf(system.top, stable.top, fallbackTopInset),
                maxOf(system.right, stable.right),
                maxOf(system.bottom, stable.bottom, keyboard.bottom)
            )
            insets
        }
        shell = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(page)
        }
        if (showNavigation) shell.addView(topBar(), LinearLayout.LayoutParams(-1, dp(62)))
        content = FrameLayout(this)
        currentScroller = null
        shell.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(6), dp(8), dp(6), dp(8))
            background = rounded(surface, 0f, line, 1)
            elevation = dp(10).toFloat()
            visibility = if (showNavigation) View.VISIBLE else View.GONE
        }
        if (showNavigation) {
            navItem(R.drawable.ic_contacts, t("Контакты", "Тамосҳо"), homePage == HomePage.Contacts) { showContacts() }
            navItem(R.drawable.ic_call, t("Звонки", "Зангҳо"), homePage == HomePage.Calls) { showCalls() }
            navItem(R.drawable.ic_chat, t("Чат", "Чат"), homePage == HomePage.Chat) { showChats() }
        }
        shell.addView(bottomBar, LinearLayout.LayoutParams(-1, dp(76)))
        rootContainer.addView(shell, FrameLayout.LayoutParams(-1, -1))
        setContentView(rootContainer)
        // Insets must be requested after the view is attached. Requesting them before
        // setContentView is ignored on a number of Huawei/Honor firmware versions.
        rootContainer.post { ViewCompat.requestApplyInsets(rootContainer) }
    }

    private fun topBar(): FrameLayout = FrameLayout(this).apply {
        setPadding(dp(16), dp(7), dp(14), dp(7))
        setBackgroundColor(surface)
        elevation = dp(2).toFloat()
        addView(TextView(this@MainActivity).apply {
            text = "Tvoice"
            textSize = 21f
            setTextColor(blue)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        }, FrameLayout.LayoutParams(-1, -1))
        addView(TextView(this@MainActivity).apply {
            text = ownNumber.take(2).ifBlank { "T" }
            textSize = 15f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            background = rounded(blue, dp(21).toFloat())
            setOnClickListener { showAccountDrawer() }
        }, FrameLayout.LayoutParams(dp(42), dp(42), Gravity.END or Gravity.CENTER_VERTICAL))
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
            currentScroller = scroller
            content.addView(scroller, FrameLayout.LayoutParams(-1, -1))
        } else {
            currentScroller = null
            content.addView(body, FrameLayout.LayoutParams(-1, -1))
        }
        return body
    }

    private fun showLogin() {
        createShell(false)
        val body = screen().apply { gravity = Gravity.CENTER_HORIZONTAL }
        val logo = ImageView(this).apply {
            setImageResource(R.drawable.ic_tvoice); setPadding(dp(6), dp(6), dp(6), dp(6))
            background = rounded(Color.WHITE, dp(46).toFloat(), line, 1); elevation = dp(4).toFloat()
        }
        body.addView(logo, LinearLayout.LayoutParams(dp(92), dp(92)).apply { topMargin = dp(34) })
        heading(body, "Tvoice", 38, blue, 18).apply { gravity = Gravity.CENTER; letterSpacing = -0.03f }
        heading(body, t("Добро пожаловать", "Хуш омадед"), 25, dark, 34)
        sub(body, t("Войдите в свою учётную запись", "Ба ҳисоби худ ворид шавед"), 15, muted, 6)

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(18), dp(18), dp(18))
            background = rounded(surface, dp(20).toFloat(), line, 1)
            elevation = dp(3).toFloat()
        }
        body.addView(card, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(28) })
        val username = modernEdit(card, t("SIP-номер", "Рақами SIP"), t("Например, 70707", "Масалан, 70707"), false)
        val password = modernEdit(card, t("Пароль", "Рамз"), t("Введите пароль", "Рамзро ворид кунед"), true)
        keepLoginFieldAboveKeyboard(username)
        keepLoginFieldAboveKeyboard(password)
        primaryButton(card, t("Войти", "Ворид шудан"), blue, 20) {
            ownNumber = username.text.toString().trim()
            pendingPassword = password.text.toString()
            if (ownNumber.isBlank() || pendingPassword.isBlank()) toast(t("Введите номер и пароль", "Рақам ва рамзро ворид кунед"))
            else ensureAudioPermissionAndLogin()
        }
    }

    private fun ensureAudioPermissionAndLogin() {
        val missing = mutableListOf<String>()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            missing += Manifest.permission.RECORD_AUDIO
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            missing += Manifest.permission.POST_NOTIFICATIONS
        }
        if (missing.isNotEmpty()) ActivityCompat.requestPermissions(this, missing.toTypedArray(), 10)
        else ensureFullScreenAccessAndLogin()
    }

    private fun ensureFullScreenAccessAndLogin() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
            getSystemService(NotificationManager::class.java).canUseFullScreenIntent()
        ) {
            register()
            return
        }
        AlertDialog.Builder(this)
            .setTitle(t("Показывать входящие звонки", "Намоиши зангҳои воридотӣ"))
            .setMessage(t("Разрешите Tvoice открывать экран входящего звонка поверх экрана блокировки.", "Ба Tvoice иҷозат диҳед, ки равзанаи зангро дар экрани қулф нишон диҳад."))
            .setNegativeButton(t("Позже", "Баъдтар")) { _, _ -> register() }
            .setPositiveButton(t("Открыть настройки", "Кушодани танзимот")) { _, _ ->
                val settings = Intent(
                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                    Uri.parse("package:$packageName")
                )
                runCatching { startActivityForResult(settings, 12) }.onFailure { register() }
            }
            .show()
    }

    private fun register() {
        startSipService(restore = false)
        showConnecting()
        try { sip.login(ownNumber, pendingPassword) }
        catch (e: Exception) { toast(e.message ?: "Ошибка регистрации"); showLogin() }
    }

    private fun showConnecting() {
        createShell(false)
        val body = screen().apply { gravity = Gravity.CENTER }
        heading(body, ownNumber, 32, blue, 130)
        sub(body, t("Подключение к Tvoice…", "Пайвастшавӣ ба Tvoice…"), 17, muted, 10)
        body.addView(ProgressBar(this), LinearLayout.LayoutParams(dp(52), dp(52)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(28) })
    }

    private fun startSipService(restore: Boolean) {
        val action = if (restore) TvoiceCallService.ACTION_RESTORE else TvoiceCallService.ACTION_START
        ContextCompat.startForegroundService(this, Intent(this, TvoiceCallService::class.java).setAction(action))
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            10 -> {
                val microphoneIndex = permissions.indexOf(Manifest.permission.RECORD_AUDIO)
                val microphoneGranted = microphoneIndex < 0 || grantResults.getOrNull(microphoneIndex) == PackageManager.PERMISSION_GRANTED
                if (microphoneGranted) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) toast(t("Разрешите уведомления, чтобы видеть входящие звонки", "Огоҳиномаҳоро барои дидани зангҳо иҷозат диҳед"))
                    ensureFullScreenAccessAndLogin()
                } else toast(t("Для звонков нужен доступ к микрофону", "Барои зангҳо дастрасӣ ба микрофон лозим аст"))
            }
            11 -> showContacts()
            13 -> if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
                toast(t(
                    "Android не разрешил уведомления. Их можно оставить включёнными в Tvoice и разрешить позже.",
                    "Android ба огоҳиномаҳо иҷозат надод. Онҳоро дар Tvoice фаъол монда, баъдтар иҷозат додан мумкин аст."
                ))
            }
        }
    }

    private fun showDialer() {
        homePage = HomePage.Calls
        createShell()
        val body = screen().apply { gravity = Gravity.CENTER_HORIZONTAL }
        heading(body, ownNumber, 28, blue, 0).gravity = Gravity.CENTER
        sub(body, t("● В сети", "● Дар шабака"), 14, green, 3).gravity = Gravity.CENTER
        val numberBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(8), 0); background = rounded(surface, dp(18).toFloat(), line, 1)
        }
        val numberView = TextView(this).apply {
            text = dialedNumber.ifEmpty { t("Введите номер", "Рақамро ворид кунед") }; textSize = if (dialedNumber.isEmpty()) 20f else 32f
            setTextColor(if (dialedNumber.isEmpty()) muted else dark); gravity = Gravity.CENTER
        }
        numberBar.addView(numberView, LinearLayout.LayoutParams(0, dp(70), 1f))
        val erase = iconCircle(R.drawable.ic_backspace, surface, dark) {
            dialedNumber = dialedNumber.dropLast(1); updateDialText(numberView)
        }
        numberBar.addView(erase, LinearLayout.LayoutParams(dp(48), dp(48)))
        body.addView(numberBar, LinearLayout.LayoutParams(-1, dp(72)).apply { topMargin = dp(20) })
        val keys = arrayOf(arrayOf("1","2","3"), arrayOf("4","5","6"), arrayOf("7","8","9"), arrayOf("0"))
        keys.forEach { rowKeys ->
            val row = LinearLayout(this).apply { gravity = Gravity.CENTER }
            rowKeys.forEach { key ->
                val keyView = TextView(this).apply {
                    text = key; textSize = 28f; setTextColor(dark); gravity = Gravity.CENTER
                    background = rounded(surface, dp(35).toFloat(), line, 1)
                    elevation = dp(2).toFloat()
                    setOnClickListener { dialedNumber += key; updateDialText(numberView) }
                }
                row.addView(keyView, LinearLayout.LayoutParams(dp(78), dp(70)).apply { setMargins(dp(7), dp(6), dp(7), dp(6)) })
            }
            body.addView(row)
        }
        val call = iconCircle(R.drawable.ic_call, green, Color.WHITE) {
            if (dialedNumber.isBlank()) toast(t("Введите номер", "Рақамро ворид кунед"))
            else placeCall(dialedNumber)
        }
        body.addView(call, LinearLayout.LayoutParams(dp(78), dp(78)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(12) })
    }

    private fun updateDialText(numberView: TextView) {
        numberView.text = dialedNumber.ifEmpty { t("Введите номер", "Рақамро ворид кунед") }
        numberView.textSize = if (dialedNumber.isEmpty()) 20f else 32f
        numberView.setTextColor(if (dialedNumber.isEmpty()) muted else dark)
    }

    private fun accountHeader(body: LinearLayout) {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(13), dp(16), dp(13)); background = rounded(surface, dp(18).toFloat(), line, 1)
        }
        val avatar = TextView(this).apply {
            text = ownNumber.take(2); textSize = 18f; setTextColor(Color.WHITE); gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD; background = rounded(blue, dp(24).toFloat())
        }
        card.addView(avatar, LinearLayout.LayoutParams(dp(48), dp(48)))
        val info = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(13), 0, 0, 0) }
        heading(info, ownNumber, 20, dark, 0)
        sub(info, t("● В сети", "● Дар шабака"), 14, green, 3)
        card.addView(info, LinearLayout.LayoutParams(0, -2, 1f))
        body.addView(card, LinearLayout.LayoutParams(-1, -2))
    }

    private fun showCalls() {
        homePage = HomePage.Calls
        currentChatPeer = null
        createShell()
        val body = screen()
        heading(body, t("Звонки", "Зангҳо"), 27, dark, 0)
        sub(body, t("История вызовов", "Таърихи зангҳо"), 14, muted, 5)
        if (callHistory.isEmpty()) {
            emptyState(
                body,
                R.drawable.ic_history,
                t("История пока пуста", "Таърих ҳоло холӣ аст"),
                t("Нажмите кнопку клавиатуры, чтобы позвонить", "Барои занг задан тугмаи рақамгириро пахш кунед")
            )
        } else {
            callHistory.forEach { item ->
                historyCard(body, item)
            }
        }
        addDialFab()
    }

    private fun historyCard(parent: LinearLayout, item: HistoryItem) {
        val accent = if (item.direction == "Входящий") green else blue
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(12), dp(13), dp(12))
            background = rounded(surface, dp(17).toFloat(), line, 1)
            setOnClickListener {
                dialedNumber = item.number
                showDialer()
            }
        }
        val avatar = TextView(this).apply {
            text = avatarSymbols(item.number, item.number)
            textSize = 16f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            background = rounded(accent, dp(24).toFloat())
        }
        row.addView(avatar, LinearLayout.LayoutParams(dp(48), dp(48)))
        val info = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(13), 0, dp(10), 0)
        }
        heading(info, item.number, 16, dark, 0)
        sub(
            info,
            "${if (item.direction == "Входящий") t("Входящий", "Воридотӣ") else t("Исходящий", "Содиротӣ")} • ${item.time}",
            13,
            muted,
            3
        )
        row.addView(info, LinearLayout.LayoutParams(0, -2, 1f))
        row.addView(View(this).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(dp(1), dp(34)))
        row.addView(TextView(this).apply {
            text = formatDuration(item.durationSeconds)
            textSize = 14f
            setTextColor(blue)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
        }, LinearLayout.LayoutParams(dp(64), dp(48)).apply { leftMargin = dp(10) })
        parent.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(9) })
    }

    private fun showContacts() {
        homePage = HomePage.Contacts
        currentChatPeer = null
        createShell(); val body = screen()
        heading(body, t("Контакты", "Тамосҳо"), 27, dark, 4)
        sub(body, t("Телефонная книга устройства", "Дафтари тамосҳои телефон"), 14, muted, 5)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            emptyState(body, R.drawable.ic_contacts, t("Разрешите доступ к контактам", "Дастрасӣ ба тамосҳоро иҷозат диҳед"), t("Tvoice покажет контакты только на этом устройстве", "Tvoice тамосҳои ҳамин телефонро нишон медиҳад"))
            primaryButton(body, t("Разрешить доступ", "Иҷозат додан"), blue, 18) { ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_CONTACTS), 11) }
            return
        }
        val contacts = loadContacts()
        if (contacts.isEmpty()) emptyState(body, R.drawable.ic_contacts, t("Контакты не найдены", "Тамосҳо ёфт нашуданд"), t("Добавьте контакт в телефонную книгу", "Ба дафтари телефон тамос илова кунед"))
        else contacts.forEach { (name, phone) -> contactCard(body, name, phone) }
    }

    private fun contactCard(parent: LinearLayout, name: String, phone: String) {
        val normalized = phone.filter { it.isDigit() || it == '+' }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(11), dp(10), dp(11))
            background = rounded(surface, dp(17).toFloat(), line, 1)
            setOnClickListener {
                dialedNumber = normalized
                showDialer()
            }
        }
        val avatar = TextView(this).apply {
            text = avatarSymbols(name, normalized)
            textSize = 16f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            background = rounded(cyan, dp(24).toFloat())
        }
        row.addView(avatar, LinearLayout.LayoutParams(dp(48), dp(48)))
        val text = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(13), 0, dp(6), 0)
        }
        heading(text, name.ifBlank { normalized }, 16, dark, 0)
        sub(text, normalized, 13, muted, 3)
        row.addView(text, LinearLayout.LayoutParams(0, -2, 1f))
        val call = ImageView(this).apply {
            setImageResource(R.drawable.ic_call)
            setColorFilter(blue)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            contentDescription = t("Позвонить", "Занг задан")
            background = rounded(if (isDarkTheme) Color.rgb(30, 58, 110) else Color.rgb(237, 243, 255), dp(22).toFloat())
            setOnClickListener { placeCall(normalized) }
        }
        row.addView(call, LinearLayout.LayoutParams(dp(44), dp(44)))
        parent.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(9) })
    }

    private fun addDialFab() {
        val button = ImageView(this).apply {
            setImageResource(R.drawable.ic_dialpad)
            setColorFilter(Color.WHITE)
            setPadding(dp(18), dp(18), dp(18), dp(18))
            contentDescription = t("Открыть набор номера", "Кушодани рақамгирӣ")
            background = rounded(blue, dp(30).toFloat())
            elevation = dp(9).toFloat()
            setOnClickListener { showDialer() }
        }
        rootContainer.addView(
            button,
            FrameLayout.LayoutParams(dp(60), dp(60), Gravity.END or Gravity.BOTTOM).apply {
                rightMargin = dp(20)
                bottomMargin = dp(92)
            }
        )
    }

    private fun placeCall(number: String) {
        val normalized = number.filter { it.isDigit() || it == '+' }
        if (normalized.isBlank()) {
            toast(t("Номер контакта не указан", "Рақами тамос нишон дода нашудааст"))
            return
        }
        try {
            beginHistory(normalized, "Исходящий")
            sip.call(normalized)
        } catch (e: Exception) {
            finishHistory()
            toast(e.message ?: t("Ошибка вызова", "Хатои занг"))
        }
    }

    private fun beginHistory(number: String, direction: String) {
        if (activeHistoryItem != null) return
        connectedAtMillis = null
        HistoryItem(number, direction, now()).also {
            activeHistoryItem = it
            callHistory.add(0, it)
        }
        saveCallHistory()
    }

    private fun finishHistory() {
        val item = activeHistoryItem ?: return
        connectedAtMillis?.let { started ->
            item.durationSeconds = ((System.currentTimeMillis() - started) / 1000L).coerceAtLeast(1L)
        }
        connectedAtMillis = null
        activeHistoryItem = null
        saveCallHistory()
    }

    private fun loadCallHistory() {
        if (callHistory.isNotEmpty()) return
        runCatching {
            val source = preferences.getString("call_history", "[]").orEmpty()
            val items = org.json.JSONArray(source)
            for (index in 0 until items.length()) {
                val item = items.getJSONObject(index)
                callHistory += HistoryItem(
                    number = item.optString("number"),
                    direction = item.optString("direction"),
                    time = item.optString("time"),
                    durationSeconds = item.optLong("duration", 0L)
                )
            }
        }
    }

    private fun saveCallHistory() {
        runCatching {
            val items = org.json.JSONArray()
            callHistory.take(100).forEach { item ->
                items.put(
                    org.json.JSONObject()
                        .put("number", item.number)
                        .put("direction", item.direction)
                        .put("time", item.time)
                        .put("duration", item.durationSeconds)
                )
            }
            preferences.edit().putString("call_history", items.toString()).apply()
        }
    }

    private fun avatarSymbols(name: String, number: String): String {
        val words = name.trim()
            .split(Regex("\\s+"))
            .filter { word -> word.any { it.isLetter() } }
        if (words.size >= 2) {
            return "${words[0].first { it.isLetter() }}${words[1].first { it.isLetter() }}".uppercase(Locale.getDefault())
        }
        val firstDigit = number.firstOrNull { it.isDigit() } ?: '•'
        return "T$firstDigit"
    }

    private fun showChats() {
        homePage = HomePage.Chat
        currentChatPeer = null
        createShell()
        val body = screen()
        val titleRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val chatTitle = heading(titleRow, t("Чат", "Чат"), 27, dark, 0)
        chatTitle.layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
        val add = Button(this).apply {
            text = t("Написать", "Навиштан")
            textSize = 13f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            stateListAnimator = null
            background = rounded(blue, dp(14).toFloat())
            setOnClickListener { showNewChatDialog() }
        }
        titleRow.addView(add, LinearLayout.LayoutParams(dp(112), dp(44)))
        body.addView(titleRow, LinearLayout.LayoutParams(-1, -2))
        sub(body, t("Сообщения между абонентами Tvoice", "Паёмҳо байни муштариёни Tvoice"), 14, muted, 5)
        val conversations = ChatStore.conversations(ownNumber)
        if (conversations.isEmpty()) {
            emptyState(
                body,
                R.drawable.ic_chat,
                t("Сообщений пока нет", "Ҳоло паём нест"),
                t("Начните чат по SIP-номеру абонента", "Чатро бо рақами SIP-и муштарӣ оғоз кунед")
            )
        } else {
            conversations.forEach { chat ->
                val unread = if (chat.unread > 0) " • ${chat.unread}" else ""
                listCard(body, chat.peer, "${chat.preview.take(45)}$unread", blue) { showConversation(chat.peer) }
            }
        }
    }

    private fun showNewChatDialog() {
        val field = EditText(this).apply {
            hint = t("SIP-номер абонента", "Рақами SIP-и муштарӣ")
            inputType = InputType.TYPE_CLASS_PHONE
            setTextColor(dark)
            setHintTextColor(muted)
            setPadding(dp(16), 0, dp(16), 0)
            background = rounded(surface, dp(13).toFloat(), line, 1)
        }
        val wrap = FrameLayout(this).apply {
            setPadding(dp(20), dp(12), dp(20), 0)
            addView(field, FrameLayout.LayoutParams(-1, dp(56)))
        }
        AlertDialog.Builder(this)
            .setTitle(t("Новый чат", "Чати нав"))
            .setView(wrap)
            .setNegativeButton(t("Отмена", "Бекор кардан"), null)
            .setPositiveButton(t("Открыть", "Кушодан")) { _, _ ->
                val peer = field.text.toString().trim()
                if (peer.isBlank()) toast(t("Введите номер", "Рақамро ворид кунед")) else showConversation(peer)
            }
            .show()
    }

    private fun showConversation(peer: String) {
        homePage = HomePage.Chat
        currentChatPeer = peer
        ChatStore.markRead(ownNumber, peer)
        createShell()
        val body = screen(false).apply { setPadding(dp(14), dp(8), dp(14), dp(12)) }
        val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val back = TextView(this).apply {
            text = "‹"
            textSize = 34f
            setTextColor(blue)
            gravity = Gravity.CENTER
            setOnClickListener { showChats() }
        }
        header.addView(back, LinearLayout.LayoutParams(dp(44), dp(48)))
        val headerText = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        heading(headerText, peer, 19, dark, 0)
        sub(headerText, t("SIP-абонент", "Муштарии SIP"), 12, green, 1)
        header.addView(headerText, LinearLayout.LayoutParams(0, -2, 1f))
        body.addView(header, LinearLayout.LayoutParams(-1, dp(56)))

        val messagesColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(6), 0, dp(8))
        }
        ChatStore.messages(ownNumber, peer).forEach { message -> addMessageBubble(messagesColumn, message) }
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            addView(messagesColumn)
        }
        body.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))

        val composer = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val input = EditText(this).apply {
            hint = t("Сообщение", "Паём")
            textSize = 16f
            setTextColor(dark)
            setHintTextColor(muted)
            maxLines = 4
            setPadding(dp(15), 0, dp(15), 0)
            background = rounded(surface, dp(22).toFloat(), line, 1)
        }
        composer.addView(input, LinearLayout.LayoutParams(0, dp(48), 1f))
        val send = TextView(this).apply {
            text = "➤"
            textSize = 23f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            background = rounded(blue, dp(24).toFloat())
            setOnClickListener {
                val text = input.text.toString().trim()
                if (text.isBlank()) return@setOnClickListener
                runCatching { sip.sendMessage(peer, text) }
                    .onSuccess { input.text.clear(); showConversation(peer) }
                    .onFailure { toast(it.message ?: t("Ошибка отправки", "Хатои ирсол")) }
            }
        }
        composer.addView(send, LinearLayout.LayoutParams(dp(48), dp(48)).apply { leftMargin = dp(8) })
        body.addView(composer, LinearLayout.LayoutParams(-1, dp(52)))
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun addMessageBubble(parent: LinearLayout, message: ChatMessage) {
        val row = FrameLayout(this)
        val bubble = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(13), dp(9), dp(13), dp(7))
            background = rounded(if (message.incoming) surface else blue, dp(16).toFloat())
        }
        sub(bubble, message.text, 15, if (message.incoming) dark else Color.WHITE, 0)
        val status = when (message.status) {
            "sending" -> "…"
            "failed" -> "!"
            else -> "✓"
        }
        sub(
            bubble,
            "${formatTime(message.timestamp)} $status",
            10,
            if (message.incoming) muted else Color.rgb(210, 226, 255),
            3
        ).gravity = Gravity.END
        row.addView(
            bubble,
            FrameLayout.LayoutParams(-2, -2, if (message.incoming) Gravity.START else Gravity.END).apply {
                leftMargin = if (message.incoming) 0 else dp(48)
                rightMargin = if (message.incoming) dp(48) else 0
            }
        )
        parent.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
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

    private fun showAccount() = showAccountDrawer()

    private fun showAccountDrawer() {
        if (!::rootContainer.isInitialized) return
        val overlay = FrameLayout(this).apply { setBackgroundColor(Color.TRANSPARENT) }
        val scrim = View(this).apply { setBackgroundColor(Color.argb(105, 2, 8, 23)) }
        overlay.addView(scrim, FrameLayout.LayoutParams(-1, -1))

        val panelWidth = (resources.displayMetrics.widthPixels * 0.88f).toInt().coerceAtMost(dp(370))
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(12), dp(18), dp(14))
            setBackgroundColor(page)
            elevation = dp(18).toFloat()
            translationX = panelWidth.toFloat()
        }
        val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val title = heading(header, t("Аккаунт", "Ҳисоб"), 23, dark, 0)
        title.layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
        header.addView(TextView(this).apply {
            text = "×"
            textSize = 28f
            gravity = Gravity.CENTER
            setTextColor(muted)
            setOnClickListener { closeDrawer(overlay, panel) }
        }, LinearLayout.LayoutParams(dp(42), dp(42)))
        panel.addView(header, LinearLayout.LayoutParams(-1, dp(48)))

        val scrollBody = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val profile = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(12), dp(12), dp(12))
            background = rounded(surface, dp(18).toFloat(), line, 1)
        }
        val photoWrap = FrameLayout(this).apply { background = rounded(blue, dp(30).toFloat()) }
        profileImage = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            if (profileUri != null) setImageURI(profileUri) else {
                setImageResource(R.drawable.ic_account)
                setColorFilter(Color.WHITE)
                setPadding(dp(14), dp(14), dp(14), dp(14))
            }
        }
        photoWrap.addView(profileImage, FrameLayout.LayoutParams(-1, -1))
        photoWrap.setOnClickListener { choosePhoto() }
        profile.addView(photoWrap, LinearLayout.LayoutParams(dp(60), dp(60)))
        val profileText = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(12), 0, 0, 0) }
        heading(profileText, ownNumber, 20, dark, 0)
        sub(profileText, t("● Подключено", "● Пайваст"), 12, green, 2)
        sub(profileText, t("Нажмите на фото для замены", "Барои иваз кардан аксро пахш кунед"), 10, muted, 3)
        profile.addView(profileText, LinearLayout.LayoutParams(0, -2, 1f))
        scrollBody.addView(profile, LinearLayout.LayoutParams(-1, -2))

        compactSection(scrollBody, t("Аккаунты", "Ҳисобҳо"))
        val numbers = (accountNumbers + ownNumber).filter { it.isNotBlank() }.distinct()
        numbers.forEach { number ->
            compactSetting(
                scrollBody,
                number,
                if (number == ownNumber) t("Активный", "Фаъол") else t("Переключить", "Гузариш"),
                blue
            ) {
                if (number != ownNumber) {
                    runCatching { sip.selectAccount(number) }
                        .onSuccess { ownNumber = number; closeDrawer(overlay, panel) }
                        .onFailure { toast(it.message ?: t("Ошибка аккаунта", "Хатои ҳисоб")) }
                }
            }
        }
        compactButton(scrollBody, t("Добавить аккаунт", "Илова кардани ҳисоб"), cyan) {
            closeDrawer(overlay, panel)
            rootContainer.postDelayed({ showAddAccountDialog() }, 190)
        }

        compactSection(scrollBody, t("Настройки", "Танзимот"))
        compactSetting(
            scrollBody,
            t("Звук звонка", "Овози занг"),
            soundSettingsSummary(),
            blue
        ) { showSoundSettingsDialog() }
        compactSetting(
            scrollBody,
            t("Уведомления", "Огоҳиномаҳо"),
            notificationSettingsSummary(),
            if (notificationsEnabled() && appNotificationsEnabled()) green else red
        ) { showNotificationSettingsDialog() }
        compactSetting(
            scrollBody,
            t("Язык", "Забон"),
            if (isTajik) "Тоҷикӣ" else "Русский",
            blue
        ) { showLanguageDialog() }
        compactSetting(
            scrollBody,
            t("Оформление", "Намуди зоҳирӣ"),
            if (isDarkTheme) t("Тёмная", "Торик") else t("Светлая", "Равшан"),
            blue
        ) { showThemeDialog() }
        compactSetting(scrollBody, t("SIP-сервер", "Сервери SIP"), "185.177.2.115 • UDP", green) { }

        compactSection(scrollBody, t("О приложении", "Дар бораи барнома"))
        sub(
            scrollBody,
            t(
                "Tvoice — приложение для звонков и сообщений между абонентами вашего SIP-сервера.",
                "Tvoice — барнома барои зангҳо ва паёмҳо байни муштариёни сервери SIP-и шумо."
            ),
            12,
            muted,
            2
        )
        sub(scrollBody, "Tvoice 0.8.4 • Tvoice SIP Core 1.3", 12, blue, 7)
        sub(scrollBody, "Developed by Шогирдои Малем", 12, dark, 5).typeface = Typeface.DEFAULT_BOLD
        compactButton(scrollBody, t("Выйти из аккаунта", "Баромадан аз ҳисоб"), red) {
            sip.logout()
            stopService(Intent(this, TvoiceCallService::class.java))
            ownNumber = ""
            pendingPassword = ""
            showLogin()
        }

        val scroller = ScrollView(this).apply { isFillViewport = false; addView(scrollBody) }
        panel.addView(scroller, LinearLayout.LayoutParams(-1, 0, 1f))
        overlay.addView(panel, FrameLayout.LayoutParams(panelWidth, -1, Gravity.END))
        scrim.setOnClickListener { closeDrawer(overlay, panel) }
        rootContainer.addView(overlay, FrameLayout.LayoutParams(-1, -1))
        panel.post { panel.animate().translationX(0f).setDuration(220).start() }
    }

    private fun closeDrawer(overlay: View, panel: View) {
        panel.animate().translationX(panel.width.toFloat()).setDuration(180).withEndAction {
            if (overlay.parent != null) rootContainer.removeView(overlay)
        }.start()
    }

    private fun compactSection(parent: LinearLayout, text: String) {
        heading(parent, text, 15, dark, 14)
    }

    private fun compactSetting(parent: LinearLayout, title: String, value: String, accent: Int, action: () -> Unit) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
            background = rounded(surface, dp(13).toFloat(), line, 1)
            setOnClickListener { action() }
        }
        val label = sub(row, title, 14, dark, 0)
        label.layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
        val valueView = sub(row, value, 12, accent, 0)
        valueView.layoutParams = LinearLayout.LayoutParams(-2, -2)
        parent.addView(row, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(6) })
    }

    private fun compactButton(parent: LinearLayout, text: String, color: Int, action: () -> Unit) {
        val button = Button(this).apply {
            this.text = text
            textSize = 13f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            stateListAnimator = null
            background = rounded(color, dp(13).toFloat())
            setOnClickListener { action() }
        }
        parent.addView(button, LinearLayout.LayoutParams(-1, dp(46)).apply { topMargin = dp(8) })
    }

    private fun showLanguageDialog() {
        val values = arrayOf("Русский", "Тоҷикӣ")
        AlertDialog.Builder(this)
            .setTitle(t("Язык", "Забон"))
            .setSingleChoiceItems(values, if (isTajik) 1 else 0) { dialog, which ->
                preferences.edit().putString("language", if (which == 1) "tg" else "ru").apply()
                dialog.dismiss()
                recreate()
            }
            .show()
    }

    private fun notificationsEnabled(): Boolean =
        getSystemService(NotificationManager::class.java).areNotificationsEnabled()

    private fun soundSettingsSummary(): String {
        val sound = preferences.getBoolean(TvoiceCallService.PREF_RINGTONE_ENABLED, true)
        val vibration = preferences.getBoolean(TvoiceCallService.PREF_VIBRATION_ENABLED, true)
        return when {
            sound && vibration -> t("Звук и вибрация", "Овоз ва ларзиш")
            sound -> t("Только звук", "Танҳо овоз")
            vibration -> t("Только вибрация", "Танҳо ларзиш")
            else -> t("Без звука", "Беовоз")
        }
    }

    private fun appNotificationsEnabled(): Boolean =
        preferences.getBoolean(TvoiceCallService.PREF_CALL_NOTIFICATIONS_ENABLED, true) ||
            preferences.getBoolean(TvoiceCallService.PREF_CHAT_NOTIFICATIONS_ENABLED, true)

    private fun notificationSettingsSummary(): String {
        if (!notificationsEnabled()) return t("Нужно разрешение", "Иҷоза лозим")
        val calls = preferences.getBoolean(TvoiceCallService.PREF_CALL_NOTIFICATIONS_ENABLED, true)
        val chats = preferences.getBoolean(TvoiceCallService.PREF_CHAT_NOTIFICATIONS_ENABLED, true)
        return when {
            calls && chats -> t("Включены", "Фаъол")
            calls || chats -> t("Частично", "Қисман")
            else -> t("Выключены", "Хомӯш")
        }
    }

    private fun showSoundSettingsDialog() {
        val body = settingsDialogBody(
            t(
                "Настройте сигнал входящего звонка, не покидая Tvoice.",
                "Овози занги воридотиро бе баромадан аз Tvoice танзим кунед."
            )
        )
        settingsSwitch(
            body,
            t("Звук входящего звонка", "Овози занги воридотӣ"),
            t("Используется мелодия телефона", "Оҳанги телефон истифода мешавад"),
            TvoiceCallService.PREF_RINGTONE_ENABLED,
            true
        )
        settingsSwitch(
            body,
            t("Вибрация", "Ларзиш"),
            t("Вибрация при входящем звонке", "Ларзиш ҳангоми занги воридотӣ"),
            TvoiceCallService.PREF_VIBRATION_ENABLED,
            true
        )
        AlertDialog.Builder(this)
            .setTitle(t("Звук звонка", "Овози занг"))
            .setView(body)
            .setPositiveButton(t("Готово", "Тайёр"), null)
            .setOnDismissListener { refreshCallServiceSettings() }
            .show()
    }

    private fun showNotificationSettingsDialog() {
        val body = settingsDialogBody(
            t(
                "Выберите уведомления Tvoice. Служебное уведомление подключения требуется Android и остаётся включённым.",
                "Огоҳиномаҳои Tvoice-ро интихоб кунед. Огоҳиномаи хизматии пайвастшавӣ барои Android лозим аст."
            )
        )
        settingsSwitch(
            body,
            t("Входящие звонки", "Зангҳои воридотӣ"),
            t("Окно ответа при работе в фоне", "Равзанаи ҷавоб дар замина"),
            TvoiceCallService.PREF_CALL_NOTIFICATIONS_ENABLED,
            true,
            requestPermissionWhenEnabled = true
        )
        settingsSwitch(
            body,
            t("Сообщения чата", "Паёмҳои чат"),
            t("Уведомлять о новых сообщениях", "Дар бораи паёмҳои нав огоҳ кунад"),
            TvoiceCallService.PREF_CHAT_NOTIFICATIONS_ENABLED,
            true,
            requestPermissionWhenEnabled = true
        )
        AlertDialog.Builder(this)
            .setTitle(t("Уведомления", "Огоҳиномаҳо"))
            .setView(body)
            .setPositiveButton(t("Готово", "Тайёр"), null)
            .show()
    }

    private fun settingsDialogBody(description: String): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(18), dp(4), dp(18), dp(8))
        sub(this, description, 12, muted, 0)
    }

    private fun settingsSwitch(
        parent: LinearLayout,
        title: String,
        description: String,
        preferenceKey: String,
        defaultValue: Boolean,
        requestPermissionWhenEnabled: Boolean = false
    ) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(10), dp(8), dp(10))
            background = rounded(surface, dp(14).toFloat(), line, 1)
        }
        val texts = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        heading(texts, title, 14, dark, 0)
        sub(texts, description, 11, muted, 3)
        row.addView(texts, LinearLayout.LayoutParams(0, -2, 1f))
        val toggle = Switch(this).apply {
            isChecked = preferences.getBoolean(preferenceKey, defaultValue)
            setOnCheckedChangeListener { _, enabled ->
                preferences.edit().putBoolean(preferenceKey, enabled).apply()
                if (enabled && requestPermissionWhenEnabled) requestNotificationPermissionIfNeeded()
                refreshCallServiceSettings()
            }
        }
        row.setOnClickListener { toggle.isChecked = !toggle.isChecked }
        row.addView(toggle, LinearLayout.LayoutParams(-2, -2))
        parent.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 13)
        }
    }

    private fun refreshCallServiceSettings() {
        startService(
            Intent(this, TvoiceCallService::class.java)
                .setAction(TvoiceCallService.ACTION_SETTINGS_CHANGED)
        )
    }

    private fun showThemeDialog() {
        val values = arrayOf(t("Светлая", "Равшан"), t("Тёмная", "Торик"))
        AlertDialog.Builder(this)
            .setTitle(t("Оформление", "Намуди зоҳирӣ"))
            .setSingleChoiceItems(values, if (isDarkTheme) 1 else 0) { dialog, which ->
                preferences.edit().putString("theme", if (which == 1) "dark" else "light").apply()
                dialog.dismiss()
                recreate()
            }
            .show()
    }

    private fun showIncomingCall(remote: String) {
        createShell(false)
        val body = screen(false).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundColor(incomingPage)
            setPadding(dp(28), dp(42), dp(28), dp(36))
        }
        sub(body, "Tvoice", 16, blue, 0).apply {
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
        val avatar = TextView(this).apply {
            text = remote.take(2)
            textSize = 30f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            background = rounded(blue, dp(48).toFloat())
        }
        body.addView(avatar, LinearLayout.LayoutParams(dp(96), dp(96)).apply { topMargin = dp(72) })
        heading(body, remote, 34, dark, 24).gravity = Gravity.CENTER
        sub(body, t("Входящий звонок", "Занги воридотӣ"), 17, muted, 10).gravity = Gravity.CENTER
        body.addView(Space(this), LinearLayout.LayoutParams(1, 0, 1f))

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        actions.addView(incomingAction(R.drawable.ic_call_end, red, t("Отклонить", "Рад кардан")) { sip.hangup() }, LinearLayout.LayoutParams(0, dp(126), 1f))
        actions.addView(incomingAction(R.drawable.ic_call, green, t("Ответить", "Ҷавоб додан")) { sip.accept() }, LinearLayout.LayoutParams(0, dp(126), 1f))
        body.addView(actions, LinearLayout.LayoutParams(-1, dp(126)))
        notifyIncomingScreenVisible()
    }

    private fun notifyIncomingScreenVisible() {
        startService(
            Intent(this, TvoiceCallService::class.java)
                .setAction(TvoiceCallService.ACTION_INCOMING_SCREEN_VISIBLE)
        )
    }

    private fun showCall(remote: String, state: String) {
        createShell(false)
        val screenHeight = resources.configuration.screenHeightDp
        val screenWidth = resources.configuration.screenWidthDp
        val veryCompact = screenHeight < 630
        val compact = screenHeight < 740
        val horizontalPadding = if (screenWidth < 360) 14 else if (compact) 18 else 24
        val verticalPadding = if (veryCompact) 12 else if (compact) 20 else 30
        val primarySize = if (veryCompact) 64 else if (compact) 72 else 80
        val rowHeight = if (veryCompact) 72 else if (compact) 84 else 98
        val keypadHeight = if (veryCompact) 164 else if (compact) 196 else 230
        val body = screen(false).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(callPageTop, callPageBottom))
            setPadding(dp(horizontalPadding), dp(verticalPadding), dp(horizontalPadding), dp(verticalPadding))
        }
        val avatar = TextView(this).apply {
            text = avatarSymbols("", remote)
            textSize = if (veryCompact) 22f else 26f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            background = rounded(blue, dp(primarySize / 2).toFloat())
        }
        body.addView(avatar, LinearLayout.LayoutParams(dp(primarySize), dp(primarySize)))
        heading(body, remote, if (veryCompact) 30 else if (compact) 34 else 38, dark, if (compact) 14 else 20).apply {
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
        }
        sub(body, state, if (veryCompact) 14 else 16, if (isDarkTheme) cyan else Color.rgb(47, 107, 219), 6).apply {
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
        }
        val spacer = Space(this); body.addView(spacer, LinearLayout.LayoutParams(1, 0, 1f))
        val keypad = callKeypad(compact).apply { visibility = View.GONE }
        body.addView(keypad, LinearLayout.LayoutParams(-1, dp(keypadHeight)))
        val firstRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        firstRow.addView(toggleCallControl(R.drawable.ic_mic, R.drawable.ic_mic_off, t("Микрофон", "Микрофон"), compact) { sip.toggleMute() }, LinearLayout.LayoutParams(0, dp(rowHeight), 1f))
        firstRow.addView(toggleCallControl(R.drawable.ic_dialpad, R.drawable.ic_dialpad, t("Клавиатура", "Тугмаҳо"), compact) { keypad.visibility = if (keypad.visibility == View.VISIBLE) View.GONE else View.VISIBLE; keypad.visibility == View.VISIBLE }, LinearLayout.LayoutParams(0, dp(rowHeight), 1f))
        firstRow.addView(toggleCallControl(R.drawable.ic_speaker, R.drawable.ic_speaker_off, t("Динамик", "Баландгӯяк"), compact) { sip.toggleSpeaker() }, LinearLayout.LayoutParams(0, dp(rowHeight), 1f))
        body.addView(firstRow, LinearLayout.LayoutParams(-1, dp(rowHeight)))
        val secondRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        secondRow.addView(toggleCallControl(R.drawable.ic_pause, R.drawable.ic_play, t("Удержание", "Нигоҳдорӣ"), compact) { sip.toggleHold() }, LinearLayout.LayoutParams(0, dp(rowHeight), 1f))
        secondRow.addView(toggleCallControl(R.drawable.ic_group_add, R.drawable.ic_group_add, t("Конференция", "Конфронс"), compact) { showConferenceDialog(); true }, LinearLayout.LayoutParams(0, dp(rowHeight), 1f))
        body.addView(secondRow, LinearLayout.LayoutParams(-1, dp(rowHeight)))
        val end = ImageView(this).apply {
            setImageResource(R.drawable.ic_call_end)
            setColorFilter(Color.WHITE)
            setPadding(dp(if (compact) 18 else 21), dp(if (compact) 18 else 21), dp(if (compact) 18 else 21), dp(if (compact) 18 else 21))
            background = rounded(red, dp(primarySize / 2).toFloat(), line, 1)
            elevation = dp(3).toFloat()
            setOnClickListener { sip.hangup() }
        }
        body.addView(end, LinearLayout.LayoutParams(dp(primarySize), dp(primarySize)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            topMargin = dp(if (veryCompact) 4 else 8)
        })
    }

    override fun onRegistration(state: RegistrationState, message: String) = runOnUiThread {
        when (state) {
            RegistrationState.Ok -> {
                ownNumber = TvoiceRuntime.activeUsername
                if (addingAccount) {
                    accountNumbers.add(pendingAddedNumber); ownNumber = pendingAddedNumber; addingAccount = false; showAccount()
                } else {
                    if (ownNumber.isNotEmpty() && ownNumber !in accountNumbers) accountNumbers.add(ownNumber)
                    intent.getStringExtra(EXTRA_OPEN_CHAT)?.let(::showConversation) ?: showCalls()
                }
            }
            RegistrationState.Failed -> if (ownNumber.isNotEmpty()) {
                val fatal = message.contains("логин", true) ||
                    message.contains("пароль", true) ||
                    message.startsWith("SIP 403")
                toast(t("Нет связи: $message", "Пайваст нест: $message"))
                if (fatal) showLogin() else showConnecting()
            }
            RegistrationState.Cleared -> if (ownNumber.isNotEmpty()) showLogin()
            else -> Unit
        }
    }

    override fun onCall(state: CallState, remote: String, message: String) = runOnUiThread {
        if (state == CallState.IncomingReceived) {
            beginHistory(remote, "Входящий")
        }
        if ((state == CallState.Connected || state == CallState.StreamsRunning) && connectedAtMillis == null) {
            connectedAtMillis = System.currentTimeMillis()
        }
        if (state == CallState.End || state == CallState.Error || state == CallState.Released) {
            finishHistory()
        }
        if (!TvoiceRuntime.isMainUiVisible) return@runOnUiThread
        when (state) {
            CallState.IncomingReceived -> showIncomingCall(remote)
            CallState.OutgoingInit, CallState.OutgoingProgress, CallState.OutgoingRinging -> showCall(remote, t("Вызов…", "Занг…"))
            CallState.Connected, CallState.StreamsRunning -> showCall(remote, t("Соединено", "Пайваст"))
            CallState.Paused -> showCall(remote, t("Удержание", "Нигоҳдорӣ"))
            CallState.Error -> {
                toast("Ошибка звонка: $message")
                showCalls()
            }
            CallState.End -> {
                if (message.isNotBlank()) toast(message)
                showCalls()
            }
            CallState.Released -> Unit
            else -> Unit
        }
    }

    override fun onMessage(state: MessageState, remote: String, text: String, message: String) = runOnUiThread {
        if (currentChatPeer == remote && TvoiceRuntime.isMainUiVisible) {
            showConversation(remote)
        } else if (state == MessageState.Received && TvoiceRuntime.isMainUiVisible) {
            toast(t("Новое сообщение от $remote", "Паёми нав аз $remote"))
            if (homePage == HomePage.Chat) showChats()
        } else if (state == MessageState.Error && TvoiceRuntime.isMainUiVisible) {
            toast(t("Не удалось отправить: $message", "Ирсол нашуд: $message"))
        }
    }

    private fun navItem(icon: Int, label: String, selected: Boolean, action: () -> Unit) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            if (selected) background = rounded(if (isDarkTheme) Color.rgb(30, 58, 110) else Color.rgb(235, 241, 255), dp(14).toFloat())
            val i = ImageView(this@MainActivity).apply { setImageResource(icon); setColorFilter(if (selected) blue else muted); setPadding(dp(4), dp(4), dp(4), dp(4)) }
            val l = TextView(this@MainActivity).apply { text = label; textSize = 11f; setTextColor(if (selected) blue else muted); gravity = Gravity.CENTER; typeface = if (selected) Typeface.DEFAULT_BOLD else Typeface.DEFAULT }
            addView(i, LinearLayout.LayoutParams(dp(30), dp(30))); addView(l, LinearLayout.LayoutParams(-1, dp(23))); setOnClickListener { action() }
        }
        bottomBar.addView(box, LinearLayout.LayoutParams(0, -1, 1f))
    }

    private fun choosePhoto() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "image/*"; addCategory(Intent.CATEGORY_OPENABLE); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) }
        startActivityForResult(intent, 20)
    }

    @Deprecated("Legacy result API used for broad Android compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 12) {
            register()
            return
        }
        if (requestCode == 20 && resultCode == RESULT_OK) {
            data?.data?.let { uri ->
                runCatching { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                profileUri = uri
                getSharedPreferences("tvoice", MODE_PRIVATE).edit().putString("profile_uri", uri.toString()).apply()
                profileImage?.clearColorFilter(); profileImage?.setPadding(dp(2), dp(2), dp(2), dp(2)); profileImage?.setImageURI(uri)
            }
        }
    }

    private fun showAddAccountDialog() {
        val panel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(8), dp(20), 0) }
        val number = modernEdit(panel, t("SIP-номер", "Рақами SIP"), t("Например, 70707", "Масалан, 70707"), false)
        val password = modernEdit(panel, t("Пароль", "Рамз"), t("Введите пароль", "Рамзро ворид кунед"), true)
        val dialog = AlertDialog.Builder(this).setTitle(t("Добавить аккаунт", "Илова кардани ҳисоб")).setView(panel)
            .setNegativeButton(t("Отмена", "Бекор кардан"), null).setPositiveButton(t("Добавить", "Илова кардан"), null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val user = number.text.toString().trim(); val pass = password.text.toString()
                if (user.isBlank() || pass.isBlank()) toast(t("Введите номер и пароль", "Рақам ва рамзро ворид кунед"))
                else try {
                    addingAccount = true; pendingAddedNumber = user; sip.addAccount(user, pass); dialog.dismiss()
                    toast("Подключение аккаунта $user…")
                } catch (e: Exception) { addingAccount = false; toast(e.message ?: "Не удалось добавить аккаунт") }
            }
        }
        dialog.show()
    }

    private fun showConferenceDialog() {
        val field = EditText(this).apply { hint = t("SIP-номер участника", "Рақами SIP-и иштирокчӣ"); inputType = InputType.TYPE_CLASS_PHONE; setTextColor(dark); setHintTextColor(muted); setPadding(dp(18), 0, dp(18), 0); background = rounded(surface, dp(13).toFloat(), line, 2) }
        val wrap = FrameLayout(this).apply { setPadding(dp(20), dp(12), dp(20), 0); addView(field, FrameLayout.LayoutParams(-1, dp(58))) }
        AlertDialog.Builder(this).setTitle(t("Добавить в конференцию", "Илова ба конфронс")).setView(wrap).setNegativeButton(t("Отмена", "Бекор кардан"), null)
            .setPositiveButton(t("Позвонить", "Занг задан")) { _, _ ->
                val number = field.text.toString().trim()
                if (number.isBlank()) toast("Введите номер") else runCatching { sip.addToConference(number) }.onFailure { toast(it.message ?: "Ошибка конференции") }
            }.show()
    }

    private fun callKeypad(compact: Boolean): GridLayout = GridLayout(this).apply {
        columnCount = 3; rowCount = 4; alignmentMode = GridLayout.ALIGN_BOUNDS; useDefaultMargins = true
        listOf("1","2","3","4","5","6","7","8","9","*","0","#").forEach { digit ->
            val key = TextView(this@MainActivity).apply {
                text = digit; textSize = if (compact) 19f else 22f; setTextColor(dark); gravity = Gravity.CENTER
                background = rounded(surface, dp(if (compact) 20 else 24).toFloat(), line, 1); setOnClickListener { sip.sendDtmf(digit[0]) }
            }
            addView(key, GridLayout.LayoutParams().apply { width = dp(if (compact) 54 else 64); height = dp(if (compact) 40 else 48); columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f) })
        }
    }

    private fun toggleCallControl(icon: Int, activeIcon: Int, label: String, compact: Boolean, action: () -> Boolean) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
        val controlSize = if (compact) 52 else 60
        val iconPadding = if (compact) 14 else 16
        val image = ImageView(this@MainActivity).apply {
            setImageResource(icon); setColorFilter(blue); setPadding(dp(iconPadding), dp(iconPadding), dp(iconPadding), dp(iconPadding)); background = rounded(surface, dp(controlSize / 2).toFloat(), line, 1)
            setOnClickListener {
                val selected = action(); setImageResource(if (selected) activeIcon else icon)
                setColorFilter(if (selected) Color.WHITE else blue)
                background = rounded(if (selected) blue else surface, dp(30).toFloat(), line, 1)
            }
        }
        addView(image, LinearLayout.LayoutParams(dp(controlSize), dp(controlSize)))
        addView(TextView(this@MainActivity).apply { text = label; textSize = if (compact) 11f else 12f; gravity = Gravity.CENTER; setTextColor(dark) }, LinearLayout.LayoutParams(-1, dp(if (compact) 24 else 30)))
    }

    private fun incomingAction(icon: Int, color: Int, label: String, action: () -> Unit) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        val image = ImageView(this@MainActivity).apply {
            setImageResource(icon)
            setColorFilter(Color.WHITE)
            setPadding(dp(20), dp(20), dp(20), dp(20))
            background = rounded(color, dp(38).toFloat())
            elevation = dp(3).toFloat()
            setOnClickListener { action() }
        }
        addView(image, LinearLayout.LayoutParams(dp(76), dp(76)))
        addView(TextView(this@MainActivity).apply {
            text = label
            textSize = 14f
            setTextColor(dark)
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-1, dp(36)).apply { topMargin = dp(6) })
    }

    private fun iconCircle(icon: Int, backgroundColor: Int, iconColor: Int, action: () -> Unit) = ImageView(this).apply {
        setImageResource(icon); setColorFilter(iconColor); setPadding(dp(20), dp(20), dp(20), dp(20)); background = rounded(backgroundColor, dp(40).toFloat(), line, 1); elevation = dp(3).toFloat(); setOnClickListener { action() }
    }

    private fun modernEdit(parent: LinearLayout, label: String, hint: String, password: Boolean): EditText {
        sub(parent, label, 13, dark, if (parent.childCount == 0) 0 else 15)
        val field = EditText(this).apply {
            this.hint = hint; textSize = 17f; setTextColor(dark); setHintTextColor(Color.rgb(148, 163, 184))
            inputType = if (password) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_CLASS_PHONE
            setPadding(dp(16), 0, dp(16), 0); background = rounded(surface, dp(13).toFloat(), line, 2)
        }
        parent.addView(field, LinearLayout.LayoutParams(-1, dp(58)).apply { topMargin = dp(7) })
        return field
    }

    private fun listCard(parent: LinearLayout, title: String, detail: String, accent: Int, action: () -> Unit) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(dp(15), dp(13), dp(15), dp(13))
            background = rounded(surface, dp(16).toFloat(), line, 1); setOnClickListener { action() }
        }
        val dot = TextView(this).apply { text = avatarSymbols(title, title); textSize = 16f; setTextColor(Color.WHITE); gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD; background = rounded(accent, dp(23).toFloat()) }
        row.addView(dot, LinearLayout.LayoutParams(dp(46), dp(46)))
        val text = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(13), 0, 0, 0) }
        heading(text, title, 17, dark, 0); sub(text, detail, 13, muted, 3)
        row.addView(text, LinearLayout.LayoutParams(0, -2, 1f))
        parent.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
    }

    private fun emptyState(parent: LinearLayout, icon: Int, title: String, description: String) {
        val box = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setPadding(dp(20), dp(38), dp(20), dp(38)); background = rounded(surface, dp(20).toFloat(), line, 1) }
        val i = ImageView(this).apply { setImageResource(icon); setColorFilter(blue); setPadding(dp(7), dp(7), dp(7), dp(7)) }
        box.addView(i, LinearLayout.LayoutParams(dp(54), dp(54))); heading(box, title, 19, dark, 17); sub(box, description, 14, muted, 7)
        parent.addView(box, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(24) })
    }

    private fun settingCard(parent: LinearLayout, title: String, detail: String, value: String) {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(dp(16), dp(14), dp(16), dp(14)); background = rounded(surface, dp(15).toFloat(), line, 1) }
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

    private fun keepLoginFieldAboveKeyboard(field: EditText) {
        field.setOnFocusChangeListener { view, hasFocus ->
            if (!hasFocus) return@setOnFocusChangeListener
            // Wait until the keyboard reports its final height, then reveal the whole
            // field with a small breathing space above it.
            view.postDelayed({
                val rectangle = Rect(0, 0, view.width, view.height + dp(28))
                view.requestRectangleOnScreen(rectangle, true)
                currentScroller?.smoothScrollBy(0, dp(20))
            }, 280)
        }
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

    private fun applySystemTheme() {
        window.statusBarColor = surface
        window.navigationBarColor = page
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = !isDarkTheme
            isAppearanceLightNavigationBars = !isDarkTheme
        }
    }

    private fun t(russian: String, tajik: String): String = if (isTajik) tajik else russian
    private fun formatDuration(seconds: Long): String {
        val hours = seconds / 3600
        val minutes = (seconds % 3600) / 60
        val secs = seconds % 60
        return if (hours > 0) "%d:%02d:%02d".format(Locale.getDefault(), hours, minutes, secs)
        else "%02d:%02d".format(Locale.getDefault(), minutes, secs)
    }
    private fun formatTime(timestamp: Long) = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(timestamp))
    private fun now() = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date())
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    @Suppress("DiscouragedApi")
    private fun statusBarHeight(): Int {
        val resourceId = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (resourceId > 0) resources.getDimensionPixelSize(resourceId) else dp(24)
    }
    private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_LONG).show()
    override fun onDestroy() {
        TvoiceRuntime.removeObserver(this)
        super.onDestroy()
    }

    companion object {
        const val EXTRA_OPEN_CHAT = "tj.tvoice.app.extra.OPEN_CHAT"
    }
}
