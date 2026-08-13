package tj.tvoice.app

import android.Manifest
import android.app.AlertDialog
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.provider.ContactsContract
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.View
import android.view.ViewGroup
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.activity.OnBackPressedCallback
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.widget.doAfterTextChanged
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity(), SipManager.Observer, ChatClient.Observer {
    private val sip: TvoiceController get() = TvoiceRuntime
    private lateinit var rootContainer: FrameLayout
    private lateinit var shell: LinearLayout
    private lateinit var content: FrameLayout
    private lateinit var bottomBar: LinearLayout
    private var currentScroller: ScrollView? = null
    private var ownNumber = ""
    private val chatOwner: String get() = SipIdentity.normalize(ownNumber)
    private var pendingPassword = ""
    private var dialedNumber = ""
    private val accountNumbers = mutableListOf<String>()
    private var addingAccount = false
    private var pendingAddedNumber = ""
    private var profileUri: Uri? = null
    private var profileImage: ImageView? = null
    private lateinit var callHistoryTracker: CallHistoryTracker
    private lateinit var contactRepository: DeviceContactRepository
    private val callHistory: List<CallHistoryItem> get() = callHistoryTracker.items
    private var homePage = HomePage.Calls
    private var currentChatPeer: String? = null
    private var pendingChatAttachmentPeer = ""
    private val uiHandler = Handler(Looper.getMainLooper())
    private var callTimerRunnable: Runnable? = null
    private var activeCallBanner: View? = null
    private var activeDrawerOverlay: View? = null
    private var activeDrawerPanel: View? = null
    private var showingDialer = false
    private var showingCallScreen = false
    private var callUiMinimized = false
    private var pendingVideoNumber = ""
    private var videoLocalHolder: SurfaceHolder? = null
    private var videoRemoteHolder: SurfaceHolder? = null
    private var videoLocalView: View? = null
    private var videoRemoteView: View? = null
    private var callFilter = CallFilter.All
    private var contactSearch = ""
    private var chatSearch = ""
    private var videoControlsVisible = true
    private var videoControlsHideTask: Runnable? = null
    private var debugPreviewScreen: String? = null
    private var activeConversationMessages: LinearLayout? = null
    private var activeConversationScroll: ScrollView? = null

    private val blue: Int get() = TvoiceUi.color(this, R.color.tvoice_blue)
    private val dark: Int get() = TvoiceUi.color(this, R.color.tvoice_text_primary)
    private val cyan: Int get() = TvoiceUi.color(this, R.color.tvoice_cyan)
    private val green: Int get() = TvoiceUi.color(this, R.color.tvoice_green)
    private val red: Int get() = TvoiceUi.color(this, R.color.tvoice_red)
    private val page: Int get() = TvoiceUi.color(this, R.color.tvoice_page)
    private val surface: Int get() = TvoiceUi.color(this, R.color.tvoice_surface)
    private val incomingPage: Int get() = TvoiceUi.color(this, R.color.tvoice_blue_soft)
    private val callPageTop: Int get() = TvoiceUi.color(this, R.color.tvoice_blue_soft)
    private val callPageBottom: Int get() = page
    private val line: Int get() = TvoiceUi.color(this, R.color.tvoice_divider)
    private val muted: Int get() = TvoiceUi.color(this, R.color.tvoice_text_secondary)

    private val preferences get() = getSharedPreferences("tvoice", MODE_PRIVATE)
    private val themeMode: String get() = preferences.getString("theme", "system") ?: "system"
    private val isDarkTheme: Boolean
        get() = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    private val isTajik: Boolean get() = preferences.getString("language", "ru") == "tg"
    private val isDebuggable: Boolean
        get() = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    private enum class HomePage { Contacts, Calls, Chat, Profile }
    private enum class CallFilter { All, Missed, Favorites }

    override fun onCreate(savedInstanceState: Bundle?) {
        if (isDebuggable && intent.hasExtra(EXTRA_UI_PREVIEW)) {
            val previewPreferences = getSharedPreferences("tvoice", MODE_PRIVATE)
            previewPreferences.edit()
                .putString("theme", if (intent.getBooleanExtra(EXTRA_UI_PREVIEW_DARK, false)) "dark" else "light")
                .putString("language", intent.getStringExtra(EXTRA_UI_PREVIEW_LANGUAGE) ?: "ru")
                .apply()
        }
        val savedTheme = getSharedPreferences("tvoice", MODE_PRIVATE).getString("theme", "system")
        AppCompatDelegate.setDefaultNightMode(
            when (savedTheme) {
                "dark" -> AppCompatDelegate.MODE_NIGHT_YES
                "light" -> AppCompatDelegate.MODE_NIGHT_NO
                else -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
            }
        )
        super.onCreate(savedInstanceState)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    closeActiveDrawer() -> Unit
                    showingCallScreen && isOngoingCall() -> minimizeCall()
                    showingDialer -> showCalls()
                    currentChatPeer != null -> showChats(refresh = false)
                    homePage != HomePage.Calls -> showCalls()
                    else -> {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                        isEnabled = true
                    }
                }
            }
        })
        WindowCompat.setDecorFitsSystemWindows(window, false)
        TvoiceRuntime.initialize(this)
        savedInstanceState?.let { state ->
            homePage = state.getString(STATE_HOME_PAGE)
                ?.let { saved -> runCatching { HomePage.valueOf(saved) }.getOrNull() }
                ?: HomePage.Calls
            currentChatPeer = state.getString(STATE_CHAT_PEER)
            callUiMinimized = state.getBoolean(STATE_CALL_MINIMIZED) && isOngoingCall()
        }
        callHistoryTracker = CallHistoryTracker(CallHistoryStore(this))
        contactRepository = DeviceContactRepository(this)
        accountNumbers.clear()
        accountNumbers.addAll(TvoiceRuntime.accountUsernames())
        TvoiceRuntime.addObserver(this)
        ChatClient.addObserver(this)
        applySystemTheme()
        profileUri = preferences.getString("profile_uri", null)?.let(Uri::parse)
        loadCallHistory()
        if (isDebuggable) {
            debugPreviewScreen = intent.getStringExtra(EXTRA_UI_PREVIEW)
            if (debugPreviewScreen != null) {
                ownNumber = "73302"
                renderDebugPreview(debugPreviewScreen.orEmpty())
                return
            }
        }
        renderRuntimeState()
    }

    private fun renderDebugPreview(screen: String) {
        when (screen.lowercase(Locale.US)) {
            "login" -> showLogin()
            "calls" -> showCalls()
            "contacts" -> showContacts()
            "chats" -> showChats(refresh = false)
            "conversation" -> showConversation("73303", refresh = false)
            "profile" -> showProfile()
            "incoming" -> showIncomingCall("73303")
            "audio" -> showCall("73303", t("Соединено", "Пайваст"))
            "video" -> showVideoCall("73303", t("Соединено", "Пайваст"))
            else -> showLogin()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        renderRuntimeState()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(STATE_HOME_PAGE, homePage.name)
        outState.putString(STATE_CHAT_PEER, currentChatPeer)
        outState.putBoolean(STATE_CALL_MINIMIZED, callUiMinimized)
        super.onSaveInstanceState(outState)
    }

    private fun renderRuntimeState() {
        ownNumber = TvoiceRuntime.activeUsername.ifBlank { TvoiceRuntime.savedUsername().orEmpty() }
        intent.getStringExtra(EXTRA_OPEN_CHAT)?.takeIf { it.isNotBlank() }?.let { peer ->
            intent.removeExtra(EXTRA_OPEN_CHAT)
            if (isOngoingCall()) callUiMinimized = true
            showConversation(peer)
            return
        }
        when (TvoiceRuntime.callState) {
            CallState.IncomingReceived -> showIncomingCall(TvoiceRuntime.remoteNumber)
            CallState.OutgoingInit, CallState.OutgoingProgress, CallState.OutgoingRinging ->
                renderOngoingCall(t("Вызов…", "Занг…"))
            CallState.Connected, CallState.StreamsRunning -> renderOngoingCall(t("Соединено", "Пайваст"))
            CallState.Paused -> renderOngoingCall(t("Удержание", "Нигоҳдорӣ"))
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

    private fun renderOngoingCall(state: String) {
        if (callUiMinimized) showCurrentHomePage()
        else showCall(TvoiceRuntime.remoteNumber, state)
    }

    private fun showCurrentHomePage() {
        when (homePage) {
            HomePage.Contacts -> showContacts()
            HomePage.Calls -> showCalls()
            HomePage.Chat -> currentChatPeer?.let { showConversation(it, refresh = false) }
                ?: showChats(refresh = false)
            HomePage.Profile -> showProfile()
        }
    }

    override fun onStart() {
        super.onStart()
        TvoiceRuntime.setMainUiVisible(true)
        if (isDebuggable && debugPreviewScreen != null) return
        when (TvoiceRuntime.callState) {
            CallState.IncomingReceived,
            CallState.OutgoingInit,
            CallState.OutgoingProgress,
            CallState.OutgoingRinging,
            CallState.Connected,
            CallState.StreamsRunning,
            CallState.Paused -> renderRuntimeState()
            else -> if (showingCallScreen || callUiMinimized) {
                callUiMinimized = false
                showCurrentHomePage()
            }
        }
    }

    override fun onStop() {
        TvoiceRuntime.setMainUiVisible(false)
        stopCallTimer()
        super.onStop()
    }

    private fun createShell(showNavigation: Boolean = true) {
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        stopCallTimer()
        if (videoLocalHolder != null || videoRemoteHolder != null) {
            sip.setVideoSurfaces(null, null)
            videoLocalHolder = null
            videoRemoteHolder = null
        }
        videoLocalView = null
        videoRemoteView = null
        activeConversationMessages = null
        activeConversationScroll = null
        activeCallBanner = null
        activeDrawerOverlay = null
        activeDrawerPanel = null
        showingDialer = false
        showingCallScreen = false
        val fallbackTopInset = statusBarHeight()
        val attachedInsets = ViewCompat.getRootWindowInsets(window.decorView)
        val attachedSystem = attachedInsets?.let { insets ->
            val types = WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
            val visible = insets.getInsets(types)
            val stable = insets.getInsetsIgnoringVisibility(types)
            intArrayOf(
                maxOf(visible.left, stable.left),
                maxOf(visible.top, stable.top, fallbackTopInset),
                maxOf(visible.right, stable.right),
                maxOf(visible.bottom, stable.bottom)
            )
        } ?: intArrayOf(0, fallbackTopInset, 0, 0)
        rootContainer = FrameLayout(this).apply {
            setBackgroundColor(page)
            // EMUI/Huawei can deliver the first WindowInsets event late (or not at all
            // when the content view is replaced). Keep the header below the status bar
            // from the very first frame and replace this fallback with real insets below.
            setPadding(attachedSystem[0], attachedSystem[1], attachedSystem[2], attachedSystem[3])
        }
        ViewCompat.setOnApplyWindowInsetsListener(rootContainer) { view, insets ->
            val types = WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
            val system = insets.getInsets(types)
            val stable = insets.getInsetsIgnoringVisibility(types)
            val left = maxOf(system.left, stable.left)
            val top = maxOf(system.top, stable.top, fallbackTopInset)
            val right = maxOf(system.right, stable.right)
            val bottom = maxOf(system.bottom, stable.bottom)
            // adjustResize already accounts for the IME. Adding ime.bottom here a
            // second time made chats jump up and then settle after every rebuild.
            if (view.paddingLeft != left || view.paddingTop != top ||
                view.paddingRight != right || view.paddingBottom != bottom
            ) view.setPadding(left, top, right, bottom)
            insets
        }
        shell = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(page)
        }
        if (showNavigation) {
            if (isOngoingCall()) {
                val banner = activeCallBannerView()
                activeCallBanner = banner
                shell.addView(banner, LinearLayout.LayoutParams(-1, dp(58)))
            }
        }
        content = FrameLayout(this)
        currentScroller = null
        shell.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(4), dp(4), dp(4), dp(4))
            background = rounded(surface, 0f, line, 1)
            elevation = 0f
            visibility = if (showNavigation) View.VISIBLE else View.GONE
        }
        if (showNavigation) {
            navItem(R.drawable.ic_contacts, t("Контакты", "Тамосҳо"), homePage == HomePage.Contacts) { switchHomePage(HomePage.Contacts) }
            navItem(R.drawable.ic_call, t("Звонки", "Зангҳо"), homePage == HomePage.Calls) { switchHomePage(HomePage.Calls) }
            navItem(R.drawable.ic_chat, t("Чаты", "Чатҳо"), homePage == HomePage.Chat) { switchHomePage(HomePage.Chat) }
            navItem(R.drawable.ic_account, t("Аккаунт", "Ҳисоб"), homePage == HomePage.Profile) { switchHomePage(HomePage.Profile) }
        }
        shell.addView(bottomBar, LinearLayout.LayoutParams(-1, dp(TvoiceUi.BOTTOM_NAV_DP)))
        rootContainer.addView(shell, FrameLayout.LayoutParams(-1, -1))
        setContentView(rootContainer)
        // Insets must be requested after the view is attached. Requesting them before
        // setContentView is ignored on a number of Huawei/Honor firmware versions.
        rootContainer.post { ViewCompat.requestApplyInsets(rootContainer) }
    }

    private fun switchHomePage(target: HomePage) {
        if (target == homePage && currentChatPeer == null && !showingDialer) return
        when (target) {
            HomePage.Contacts -> showContacts()
            HomePage.Calls -> showCalls()
            HomePage.Chat -> showChats()
            HomePage.Profile -> showProfile()
        }
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
            setOnClickListener { showProfile() }
        }, FrameLayout.LayoutParams(dp(42), dp(42), Gravity.END or Gravity.CENTER_VERTICAL))
    }

    private fun activeCallBannerView(): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(14), dp(6), dp(10), dp(6))
        background = rounded(if (isDarkTheme) Color.rgb(24, 54, 94) else Color.rgb(230, 240, 255), 0f, line, 1)
        setOnClickListener { openCallScreen() }

        addView(ImageView(this@MainActivity).apply {
            setImageResource(R.drawable.ic_call)
            setColorFilter(Color.WHITE)
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = rounded(green, dp(18).toFloat())
        }, LinearLayout.LayoutParams(dp(36), dp(36)))

        val labels = LinearLayout(this@MainActivity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), 0, dp(8), 0)
        }
        heading(labels, TvoiceRuntime.remoteNumber, 14, dark, 0)
        sub(labels, currentCallStatus(), 11, muted, 1)
        addView(labels, LinearLayout.LayoutParams(0, -2, 1f))

        val duration = TextView(this@MainActivity).apply {
            textSize = 14f
            setTextColor(blue)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        }
        addView(duration, LinearLayout.LayoutParams(dp(64), dp(40)))
        startCallTimer(duration, fallback = currentCallStatus())

        addView(ImageView(this@MainActivity).apply {
            setImageResource(R.drawable.ic_call_end)
            setColorFilter(Color.WHITE)
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = rounded(red, dp(18).toFloat())
            contentDescription = t("Завершить звонок", "Анҷоми занг")
            setOnClickListener { sip.hangup() }
        }, LinearLayout.LayoutParams(dp(36), dp(36)))
    }

    private fun isOngoingCall(): Boolean = TvoiceRuntime.callState in setOf(
        CallState.OutgoingInit,
        CallState.OutgoingProgress,
        CallState.OutgoingRinging,
        CallState.Connected,
        CallState.StreamsRunning,
        CallState.Paused
    )

    private fun currentCallStatus(): String = when (TvoiceRuntime.callState) {
        CallState.Connected, CallState.StreamsRunning -> t("Соединено", "Пайваст")
        CallState.Paused -> t("Удержание", "Нигоҳдорӣ")
        else -> t("Вызов…", "Занг…")
    }

    private fun openCallScreen() {
        if (!isOngoingCall()) return
        callUiMinimized = false
        showCall(TvoiceRuntime.remoteNumber, currentCallStatus())
    }

    private fun minimizeCall() {
        if (!isOngoingCall()) return
        callUiMinimized = true
        showCurrentHomePage()
    }

    private fun startCallTimer(view: TextView, fallback: String = "") {
        stopCallTimer()
        val task = object : Runnable {
            override fun run() {
                val started = TvoiceRuntime.callConnectedAtMillis
                if (started == null) {
                    view.text = fallback
                } else {
                    val elapsed = ((System.currentTimeMillis() - started) / 1_000L).coerceAtLeast(0L)
                    view.text = formatDuration(elapsed)
                }
                uiHandler.postDelayed(this, 1_000L)
            }
        }
        callTimerRunnable = task
        task.run()
    }

    private fun stopCallTimer() {
        callTimerRunnable?.let(uiHandler::removeCallbacks)
        callTimerRunnable = null
    }

    private fun dismissActiveCallBanner() {
        activeCallBanner?.let { banner -> (banner.parent as? ViewGroup)?.removeView(banner) }
        activeCallBanner = null
        stopCallTimer()
    }

    private fun screen(scroll: Boolean = true): LinearLayout {
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(TvoiceUi.SCREEN_HORIZONTAL_DP), dp(12), dp(TvoiceUi.SCREEN_HORIZONTAL_DP), dp(20))
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
        body.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_tojiktelecom_mark)
            adjustViewBounds = true
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            contentDescription = "Тоҷиктелеком"
        }, LinearLayout.LayoutParams(dp(132), dp(54)).apply { topMargin = dp(20) })
        val logo = ImageView(this).apply {
            setImageResource(R.drawable.ic_tvoice)
            setPadding(dp(6), dp(6), dp(6), dp(6))
            background = rounded(surface, dp(36).toFloat(), line, 1)
        }
        body.addView(logo, LinearLayout.LayoutParams(dp(72), dp(72)).apply { topMargin = dp(18) })
        heading(body, "Tvoice", 28, blue, 10).apply { gravity = Gravity.CENTER; typeface = TvoiceUi.bold() }
        heading(body, t("Добро пожаловать!", "Хуш омадед!"), 24, dark, 28).apply { gravity = Gravity.CENTER; typeface = TvoiceUi.bold() }
        sub(body, t("Один вход для звонков и чата", "Як воридшавӣ барои занг ва чат"), TvoiceUi.BODY_SP.toInt(), muted, 6).gravity = Gravity.CENTER

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, dp(20))
        }
        body.addView(card, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(24) })
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
            14 -> {
                if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
                    toast(t("Будут показаны только контакты Tvoice", "Танҳо тамосҳои Tvoice нишон дода мешаванд"))
                }
                showNewChatDialog()
            }
            15 -> {
                val number = pendingVideoNumber
                pendingVideoNumber = ""
                if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && number.isNotBlank()) {
                    startVideoCall(number)
                } else {
                    toast(t("Для видеозвонка нужен доступ к камере", "Барои занги видеоӣ дастрасӣ ба камера лозим аст"))
                }
            }
            16 -> {
                if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && sip.isVideoCall && !sip.isVideoCameraEnabled()) {
                    sip.toggleVideoCamera()
                    refreshVideoServiceType()
                    if (showingCallScreen) showCall(TvoiceRuntime.remoteNumber, currentCallStatus())
                } else if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
                    toast(t("Камера останется выключенной", "Камера хомӯш мемонад"))
                }
            }
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
        showingDialer = true
        val compact = resources.configuration.screenHeightDp < 720
        val body = screen(false).apply { gravity = Gravity.CENTER_HORIZONTAL }
        heading(body, "Tvoice", 22, blue, 0).apply {
            gravity = Gravity.CENTER
            typeface = TvoiceUi.bold()
        }
        heading(body, ownNumber, if (compact) 20 else 24, dark, 7).gravity = Gravity.CENTER
        sub(body, t("● В сети", "● Дар шабака"), 13, green, 2).gravity = Gravity.CENTER
        body.addView(Space(this), LinearLayout.LayoutParams(1, 0, 1f))
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
        body.addView(numberBar, LinearLayout.LayoutParams(-1, dp(if (compact) 62 else 70)).apply { topMargin = dp(8) })
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
                row.addView(keyView, LinearLayout.LayoutParams(dp(if (compact) 70 else 78), dp(if (compact) 58 else 66)).apply {
                    setMargins(dp(7), dp(if (compact) 3 else 5), dp(7), dp(if (compact) 3 else 5))
                })
            }
            body.addView(row)
        }
        val actions = LinearLayout(this).apply { gravity = Gravity.CENTER }
        val videoCall = iconCircle(R.drawable.ic_videocam, blue, Color.WHITE) {
            if (dialedNumber.isBlank()) toast(t("Введите номер", "Рақамро ворид кунед"))
            else placeVideoCall(dialedNumber)
        }.apply { contentDescription = t("Начать видеозвонок", "Оғози занги видеоӣ") }
        actions.addView(videoCall, LinearLayout.LayoutParams(dp(if (compact) 64 else 70), dp(if (compact) 64 else 70)).apply { setMargins(dp(12), dp(5), dp(12), 0) })
        val call = iconCircle(R.drawable.ic_call, green, Color.WHITE) {
            if (dialedNumber.isBlank()) toast(t("Введите номер", "Рақамро ворид кунед"))
            else placeCall(dialedNumber)
        }.apply { contentDescription = t("Начать аудиозвонок", "Оғози занги овозӣ") }
        actions.addView(call, LinearLayout.LayoutParams(dp(if (compact) 68 else 76), dp(if (compact) 68 else 76)).apply { setMargins(dp(12), dp(3), dp(12), 0) })
        body.addView(actions, LinearLayout.LayoutParams(-1, dp(if (compact) 76 else 84)))
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
        pageTitle(body, t("Звонки", "Зангҳо"))
        callFilterBar(body)
        val favorites = preferences.getStringSet(PREF_FAVORITE_CALLS, emptySet()).orEmpty()
        val sourceHistory = if (debugPreviewScreen == "calls") listOf(
            CallHistoryItem("73303", "Входящий", "10:42", 185, System.currentTimeMillis()),
            CallHistoryItem("73304", "Исходящий", "09:15", 48, System.currentTimeMillis()),
            CallHistoryItem("73305", "Входящий", "Вчера", 0, System.currentTimeMillis() - 86_400_000L)
        ) else callHistory
        val visible = sourceHistory.filter { item ->
            when (callFilter) {
                CallFilter.All -> true
                CallFilter.Missed -> item.direction == "Входящий" && item.durationSeconds == 0L
                CallFilter.Favorites -> item.number in favorites
            }
        }
        if (visible.isEmpty()) {
            emptyState(
                body,
                R.drawable.ic_history,
                if (callFilter == CallFilter.All) t("История пока пуста", "Таърих ҳоло холӣ аст") else t("В этом разделе пока нет звонков", "Дар ин бахш ҳоло занг нест"),
                t("Нажмите кнопку клавиатуры, чтобы позвонить", "Барои занг задан тугмаи рақамгириро пахш кунед")
            )
        } else {
            var lastGroup = ""
            visible.forEach { item ->
                val group = callDayLabel(item.timestampMillis)
                if (group != lastGroup) {
                    sectionLabel(body, group)
                    lastGroup = group
                }
                historyRow(body, item)
            }
        }
        addDialFab()
    }

    private fun callFilterBar(parent: LinearLayout) {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(3), dp(3), dp(3), dp(3))
            background = rounded(TvoiceUi.color(this@MainActivity, R.color.tvoice_search), dp(10).toFloat())
        }
        listOf(
            CallFilter.All to t("Все", "Ҳама"),
            CallFilter.Missed to t("Пропущенные", "Аздастрафта"),
            CallFilter.Favorites to t("Избранные", "Мунтахаб")
        ).forEach { (filter, label) ->
            bar.addView(TextView(this).apply {
                text = label
                TvoiceUi.style(this, TvoiceUi.CAPTION_SP, if (callFilter == filter) Color.WHITE else muted, TvoiceUi.medium())
                gravity = Gravity.CENTER
                background = if (callFilter == filter) rounded(blue, dp(8).toFloat()) else TvoiceUi.ripple(this@MainActivity, Color.TRANSPARENT, 8)
                setOnClickListener {
                    if (callFilter != filter) {
                        callFilter = filter
                        showCalls()
                    }
                }
            }, LinearLayout.LayoutParams(0, dp(34), 1f))
        }
        parent.addView(bar, LinearLayout.LayoutParams(-1, dp(40)).apply { topMargin = dp(10) })
    }

    private fun historyRow(parent: LinearLayout, item: CallHistoryItem) {
        val missed = item.direction == "Входящий" && item.durationSeconds == 0L
        val accent = if (missed) red else green
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, dp(8))
            background = TvoiceUi.ripple(this@MainActivity, surface, 0)
            setOnClickListener {
                dialedNumber = item.number
                showDialer()
            }
        }
        val avatar = TextView(this).apply {
            text = avatarSymbols(item.number, item.number)
            textSize = TvoiceUi.LIST_TITLE_SP
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = TvoiceUi.semiBold()
            background = rounded(accent, dp(20).toFloat())
        }
        row.addView(avatar, LinearLayout.LayoutParams(dp(40), dp(40)))
        val info = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), 0, dp(8), 0)
        }
        heading(info, item.number, TvoiceUi.LIST_TITLE_SP.toInt(), dark, 0).typeface = TvoiceUi.semiBold()
        sub(
            info,
            if (missed) t("Пропущенный", "Аздастрафта") else if (item.direction == "Входящий") t("Входящий", "Воридотӣ") else t("Исходящий", "Содиротӣ"),
            TvoiceUi.SECONDARY_SP.toInt(),
            if (missed) red else muted,
            3
        )
        row.addView(info, LinearLayout.LayoutParams(0, -2, 1f))
        val meta = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.END }
        sub(meta, item.time, TvoiceUi.CAPTION_SP.toInt(), muted, 0).gravity = Gravity.END
        sub(meta, if (item.durationSeconds > 0) formatDuration(item.durationSeconds) else "—", TvoiceUi.CAPTION_SP.toInt(), muted, 4).gravity = Gravity.END
        row.addView(meta, LinearLayout.LayoutParams(dp(52), -2))
        row.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_info)
            setColorFilter(blue)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            contentDescription = t("Информация о звонке", "Маълумоти занг")
            setOnClickListener { showCallInfo(item) }
        }, LinearLayout.LayoutParams(dp(44), dp(44)).apply { leftMargin = dp(2) })
        parent.addView(row, LinearLayout.LayoutParams(-1, dp(TvoiceUi.ROW_HEIGHT_DP)))
        parent.addView(View(this).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(-1, dp(1)).apply { leftMargin = dp(52) })
    }

    private fun showCallInfo(item: CallHistoryItem) {
        val favorites = preferences.getStringSet(PREF_FAVORITE_CALLS, emptySet()).orEmpty().toMutableSet()
        val favorite = item.number in favorites
        AlertDialog.Builder(this)
            .setTitle(item.number)
            .setItems(arrayOf(
                t("Аудиозвонок", "Занги овозӣ"),
                t("Видеозвонок", "Занги видеоӣ"),
                if (favorite) t("Удалить из избранного", "Аз мунтахаб нест кардан") else t("Добавить в избранное", "Ба мунтахаб илова кардан")
            )) { dialog, which ->
                when (which) {
                    0 -> placeCall(item.number)
                    1 -> placeVideoCall(item.number)
                    2 -> {
                        if (favorite) favorites.remove(item.number) else favorites.add(item.number)
                        preferences.edit().putStringSet(PREF_FAVORITE_CALLS, favorites).apply()
                        showCalls()
                    }
                }
                dialog.dismiss()
            }
            .show()
    }

    private fun callDayLabel(timestamp: Long): String {
        val item = Calendar.getInstance().apply { timeInMillis = timestamp }
        val today = Calendar.getInstance()
        val yesterday = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }
        fun sameDay(a: Calendar, b: Calendar) = a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
        return when {
            sameDay(item, today) -> t("Сегодня", "Имрӯз")
            sameDay(item, yesterday) -> t("Вчера", "Дирӯз")
            else -> SimpleDateFormat("dd MMMM", Locale.getDefault()).format(Date(timestamp))
        }
    }

    private fun showContacts() {
        homePage = HomePage.Contacts
        currentChatPeer = null
        createShell()
        val body = screen()
        pageTitle(body, t("Контакты", "Тамосҳо"))
        val merged = mutableListOf<Pair<String, String>>()
        if (debugPreviewScreen == "contacts") {
            merged.addAll(listOf("Алишер" to "73303", "Бахтиёр" to "73304", "Дилшод" to "73305", "Мунира" to "73306"))
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) {
            merged.addAll(contactRepository.load().map { contact -> contact.name to contact.phone })
        }
        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        searchField(body, t("Поиск", "Ҷустуҷӯ"), contactSearch) { query ->
            contactSearch = query
            renderContactRows(list, merged, query)
        }
        body.addView(list, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
        renderContactRows(list, merged, contactSearch)

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            val allow = TextView(this).apply {
                text = t("Разрешить доступ к телефонной книге", "Дастрасӣ ба дафтари телефон")
                TvoiceUi.style(this, TvoiceUi.BUTTON_SP, blue, TvoiceUi.semiBold())
                gravity = Gravity.CENTER
                background = TvoiceUi.ripple(this@MainActivity, TvoiceUi.color(this@MainActivity, R.color.tvoice_blue_soft), 10)
                setOnClickListener { ActivityCompat.requestPermissions(this@MainActivity, arrayOf(Manifest.permission.READ_CONTACTS), 11) }
            }
            body.addView(allow, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(12) })
        }

        ChatClient.loadContacts { result ->
            runOnUiThread {
                result.getOrNull()?.forEach { contact ->
                    if (merged.none { SipIdentity.normalize(it.second) == contact.sipNumber }) {
                        merged += contact.displayName to contact.sipNumber
                    }
                }
                renderContactRows(list, merged, contactSearch)
            }
        }
        addContactFab()
    }

    private fun renderContactRows(parent: LinearLayout, contacts: List<Pair<String, String>>, query: String) {
        parent.removeAllViews()
        val normalizedQuery = query.trim().lowercase(Locale.getDefault())
        val filtered = contacts.distinctBy { SipIdentity.normalize(it.second) }
            .filter { (name, phone) -> normalizedQuery.isBlank() || name.lowercase(Locale.getDefault()).contains(normalizedQuery) || phone.contains(normalizedQuery) }
            .sortedBy { (name, phone) -> name.ifBlank { phone }.lowercase(Locale.getDefault()) }
        if (filtered.isEmpty()) {
            sub(parent, t("Контакты не найдены", "Тамосҳо ёфт нашуданд"), TvoiceUi.SECONDARY_SP.toInt(), muted, 24).gravity = Gravity.CENTER
            return
        }
        var group = ""
        filtered.forEach { (name, phone) ->
            val next = name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "#"
            if (next != group) {
                sectionLabel(parent, next)
                group = next
            }
            contactRow(parent, name, phone)
        }
    }

    private fun contactRow(parent: LinearLayout, name: String, phone: String) {
        val normalized = phone.filter { it.isDigit() || it == '+' }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(7), 0, dp(7))
            background = TvoiceUi.ripple(this@MainActivity, surface, 0)
            setOnClickListener {
                dialedNumber = normalized
                showDialer()
            }
        }
        val avatar = TextView(this).apply {
            text = avatarSymbols(name, normalized)
            textSize = TvoiceUi.LIST_TITLE_SP
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = TvoiceUi.semiBold()
            background = rounded(cyan, dp(20).toFloat())
        }
        row.addView(avatar, LinearLayout.LayoutParams(dp(40), dp(40)))
        val text = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(13), 0, dp(6), 0)
        }
        heading(text, name.ifBlank { normalized }, TvoiceUi.LIST_TITLE_SP.toInt(), dark, 0).apply {
            typeface = TvoiceUi.semiBold()
            maxLines = 1
        }
        sub(text, if (ChatClient.isConnected) t("Tvoice • доступен для чата", "Tvoice • барои чат дастрас") else normalized, TvoiceUi.SECONDARY_SP.toInt(), if (ChatClient.isConnected) green else muted, 3).maxLines = 1
        row.addView(text, LinearLayout.LayoutParams(0, -2, 1f))
        val call = ImageView(this).apply {
            setImageResource(R.drawable.ic_call)
            setColorFilter(blue)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            contentDescription = t("Позвонить", "Занг задан")
            background = TvoiceUi.ripple(this@MainActivity, Color.TRANSPARENT, 22)
            setOnClickListener { placeCall(normalized) }
        }
        row.addView(call, LinearLayout.LayoutParams(dp(44), dp(44)))
        row.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_videocam)
            setColorFilter(blue)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            contentDescription = t("Видеозвонок", "Занги видеоӣ")
            background = TvoiceUi.ripple(this@MainActivity, Color.TRANSPARENT, 22)
            setOnClickListener { placeVideoCall(normalized) }
        }, LinearLayout.LayoutParams(dp(44), dp(44)).apply { leftMargin = dp(6) })
        parent.addView(row, LinearLayout.LayoutParams(-1, dp(TvoiceUi.ROW_HEIGHT_DP)))
        parent.addView(View(this).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(-1, dp(1)).apply { leftMargin = dp(52) })
    }

    private fun addContactFab() {
        val button = ImageView(this).apply {
            setImageResource(R.drawable.ic_add)
            setColorFilter(Color.WHITE)
            setPadding(dp(15), dp(15), dp(15), dp(15))
            contentDescription = t("Добавить контакт", "Илова кардани тамос")
            background = rounded(blue, dp(TvoiceUi.FAB_DP / 2).toFloat())
            elevation = dp(5).toFloat()
            setOnClickListener {
                val intent = Intent(Intent.ACTION_INSERT, ContactsContract.Contacts.CONTENT_URI)
                runCatching { startActivity(intent) }.onFailure { showNewChatDialog() }
            }
        }
        rootContainer.addView(button, FrameLayout.LayoutParams(dp(TvoiceUi.FAB_DP), dp(TvoiceUi.FAB_DP), Gravity.END or Gravity.BOTTOM).apply {
            rightMargin = dp(16)
            bottomMargin = dp(74)
        })
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
            FrameLayout.LayoutParams(dp(TvoiceUi.FAB_DP), dp(TvoiceUi.FAB_DP), Gravity.END or Gravity.BOTTOM).apply {
                rightMargin = dp(16)
                bottomMargin = dp(74)
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
            callUiMinimized = false
            beginHistory(normalized, "Исходящий")
            sip.call(normalized)
        } catch (e: Exception) {
            finishHistory()
            toast(e.message ?: t("Ошибка вызова", "Хатои занг"))
        }
    }

    private fun placeVideoCall(number: String) {
        val normalized = number.filter { it.isDigit() || it == '+' }
        if (normalized.isBlank()) {
            toast(t("Номер контакта не указан", "Рақами тамос нишон дода нашудааст"))
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            pendingVideoNumber = normalized
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 15)
            return
        }
        startVideoCall(normalized)
    }

    private fun startVideoCall(number: String) {
        if (!ChatClient.isConnected) {
            toast(t("Чат-сервер ещё подключается", "Сервери чат ҳоло пайваст мешавад"))
            ChatClient.reconnect()
            return
        }
        beginHistory(number, "Исходящий видео")
        ChatClient.startVideoCall(number) { result ->
            result.onSuccess { credentials ->
                finishHistory()
                startActivity(VideoCallActivity.outgoingIntent(this, credentials))
            }.onFailure { error ->
                finishHistory()
                toast(error.message ?: t("Ошибка видеовызова", "Хатои занги видеоӣ"))
            }
        }
    }

    private fun beginHistory(number: String, direction: String) {
        callHistoryTracker.begin(number, direction, now())
    }

    private fun finishHistory() {
        callHistoryTracker.finish(System.currentTimeMillis())
    }

    private fun loadCallHistory() {
        callHistoryTracker.load()
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

    private fun showChats(refresh: Boolean = true) {
        homePage = HomePage.Chat
        currentChatPeer = null
        if (refresh) ChatClient.syncAll()
        createShell()
        val body = screen()
        pageTitle(body, t("Чаты", "Чатҳо"))
        val chatStatus = if (ChatClient.isConnected) {
            t("В сети", "Дар шабака")
        } else {
            ChatClient.stateMessage.ifBlank { t("Подключение…", "Пайвастшавӣ…") }
        }
        sub(body, chatStatus, TvoiceUi.CAPTION_SP.toInt(), if (ChatClient.isConnected) green else muted, 3)
        val conversations = if (debugPreviewScreen == "chats") listOf(
            ChatConversation("73303", t("Буду через пять минут", "Пас аз панҷ дақиқа"), System.currentTimeMillis(), 2),
            ChatConversation("73304", t("Документ отправлен", "Ҳуҷҷат фиристода шуд"), System.currentTimeMillis() - 3_600_000L, 0),
            ChatConversation("73305", t("Спасибо!", "Ташаккур!"), System.currentTimeMillis() - 86_400_000L, 0)
        ) else ChatStore.conversations(chatOwner)
        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        searchField(body, t("Поиск чатов", "Ҷустуҷӯи чатҳо"), chatSearch) { query ->
            chatSearch = query
            renderChatRows(list, conversations, query)
        }
        body.addView(list, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
        renderChatRows(list, conversations, chatSearch)
        body.addView(Space(this), LinearLayout.LayoutParams(1, dp(74)))
        addNewChatFab()
    }

    private fun renderChatRows(parent: LinearLayout, conversations: List<ChatConversation>, query: String) {
        parent.removeAllViews()
        val filtered = conversations.filter { chat ->
            query.isBlank() || chat.peer.contains(query, true) || chat.preview.contains(query, true)
        }
        if (filtered.isEmpty()) {
            emptyState(parent, R.drawable.ic_chat, t("Сообщений пока нет", "Ҳоло паём нест"), t("Начните чат по SIP-номеру абонента", "Чатро бо рақами SIP-и муштарӣ оғоз кунед"))
            return
        }
        filtered.forEach { chat -> chatConversationRow(parent, chat) }
    }

    private fun chatConversationRow(parent: LinearLayout, chat: ChatConversation) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, dp(8))
            background = TvoiceUi.ripple(this@MainActivity, surface, 0)
            setOnClickListener { showConversation(chat.peer) }
        }
        val avatarWrap = FrameLayout(this)
        avatarWrap.addView(TextView(this).apply {
            text = avatarSymbols("", chat.peer)
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            TvoiceUi.style(this, TvoiceUi.LIST_TITLE_SP, Color.WHITE, TvoiceUi.semiBold())
            background = rounded(blue, dp(20).toFloat())
        }, FrameLayout.LayoutParams(dp(40), dp(40)))
        if (ChatClient.isConnected) {
            avatarWrap.addView(View(this).apply { background = rounded(green, dp(5).toFloat()) }, FrameLayout.LayoutParams(dp(10), dp(10), Gravity.END or Gravity.BOTTOM).apply {
                rightMargin = dp(1); bottomMargin = dp(1)
            })
        }
        row.addView(avatarWrap, LinearLayout.LayoutParams(dp(40), dp(40)))
        val labels = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(12), 0, dp(8), 0) }
        heading(labels, chat.peer, TvoiceUi.LIST_TITLE_SP.toInt(), dark, 0).apply { typeface = TvoiceUi.semiBold(); maxLines = 1 }
        sub(labels, chat.preview.ifBlank { t("Вложение", "Замима") }, TvoiceUi.SECONDARY_SP.toInt(), muted, 4).apply {
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        row.addView(labels, LinearLayout.LayoutParams(0, -2, 1f))
        val meta = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.END }
        sub(meta, formatTime(chat.timestamp), TvoiceUi.CAPTION_SP.toInt(), muted, 0).gravity = Gravity.END
        if (chat.unread > 0) {
            meta.addView(TextView(this).apply {
                text = chat.unread.coerceAtMost(99).toString()
                TvoiceUi.style(this, 10f, Color.WHITE, TvoiceUi.medium())
                gravity = Gravity.CENTER
                background = rounded(blue, dp(9).toFloat())
            }, LinearLayout.LayoutParams(dp(18), dp(18)).apply { gravity = Gravity.END; topMargin = dp(4) })
        }
        row.addView(meta, LinearLayout.LayoutParams(dp(44), -2))
        parent.addView(row, LinearLayout.LayoutParams(-1, dp(TvoiceUi.ROW_HEIGHT_DP)))
        parent.addView(View(this).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(-1, dp(1)).apply { leftMargin = dp(52) })
    }

    private fun addNewChatFab() {
        val button = ImageView(this).apply {
            setImageResource(R.drawable.ic_new_chat)
            setColorFilter(Color.WHITE)
            setPadding(dp(17), dp(17), dp(17), dp(17))
            contentDescription = t("Новый чат", "Чати нав")
            background = rounded(blue, dp(TvoiceUi.FAB_DP / 2).toFloat())
            elevation = dp(5).toFloat()
            setOnClickListener { showNewChatDialog() }
        }
        content.addView(
            button,
            FrameLayout.LayoutParams(dp(TvoiceUi.FAB_DP), dp(TvoiceUi.FAB_DP), Gravity.END or Gravity.BOTTOM).apply {
                rightMargin = dp(16)
                bottomMargin = dp(10)
            }
        )
    }

    private fun showNewChatDialog() {
        val contacts = mutableListOf<Pair<String, String>>()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) {
            contacts += contactRepository.load().mapNotNull { (name, phone) ->
                runCatching { SipIdentity.requireValid(phone) }.getOrNull()?.let { name to it }
            }
        }
        lateinit var dialog: AlertDialog
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(8), dp(18), dp(12))
        }
        val search = EditText(this).apply {
            hint = t("Поиск или номер абонента", "Ҷустуҷӯ ё рақами муштарӣ")
            inputType = InputType.TYPE_CLASS_TEXT
            setSingleLine()
            setTextColor(dark)
            setHintTextColor(muted)
            setPadding(dp(15), 0, dp(15), 0)
            background = rounded(surface, dp(15).toFloat(), line, 1)
        }
        panel.addView(search, LinearLayout.LayoutParams(-1, dp(52)))

        val addContact = TextView(this).apply {
            text = "＋  ${t("Добавить новый контакт", "Илова кардани тамоси нав")}"
            textSize = 15f
            setTextColor(blue)
            gravity = Gravity.CENTER_VERTICAL
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(12), 0, dp(12), 0)
            setOnClickListener {
                runCatching {
                    startActivity(Intent(Intent.ACTION_INSERT, ContactsContract.Contacts.CONTENT_URI))
                }.onFailure { toast(t("Не удалось открыть контакты", "Кушодани тамосҳо нашуд")) }
            }
        }
        panel.addView(addContact, LinearLayout.LayoutParams(-1, dp(50)).apply { topMargin = dp(6) })

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            panel.addView(TextView(this).apply {
                text = t("Разрешить телефонную книгу", "Иҷозати дафтари телефон")
                textSize = 14f
                setTextColor(blue)
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(12), 0, dp(12), 0)
                setOnClickListener {
                    dialog.dismiss()
                    ActivityCompat.requestPermissions(
                        this@MainActivity,
                        arrayOf(Manifest.permission.READ_CONTACTS),
                        14
                    )
                }
            }, LinearLayout.LayoutParams(-1, dp(44)))
        }

        val results = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val scroll = ScrollView(this).apply { addView(results) }
        val listHeight = (resources.displayMetrics.heightPixels * 0.48f)
            .toInt()
            .coerceIn(dp(220), dp(420))
        panel.addView(scroll, LinearLayout.LayoutParams(-1, listHeight))

        fun render(queryValue: String) {
            results.removeAllViews()
            val query = queryValue.trim()
            val normalizedQuery = runCatching { SipIdentity.requireValid(query) }.getOrNull()
            if (normalizedQuery != null && contacts.none { it.second == normalizedQuery }) {
                chatContactRow(
                    results,
                    t("Написать абоненту", "Ба муштарӣ нависед"),
                    normalizedQuery
                ) {
                    dialog.dismiss()
                    showConversation(normalizedQuery)
                }
            }
            contacts.asSequence()
                .filter { query.isBlank() || it.first.contains(query, true) || it.second.contains(query) }
                .take(50)
                .forEach { (name, phone) ->
                    chatContactRow(results, name.ifBlank { phone }, phone) {
                        dialog.dismiss()
                        showConversation(phone)
                    }
                }
            if (results.childCount == 0) {
                sub(
                    results,
                    t("Контакты не найдены", "Тамосҳо ёфт нашуданд"),
                    14,
                    muted,
                    18
                ).gravity = Gravity.CENTER
            }
        }

        dialog = AlertDialog.Builder(this)
            .setTitle(t("Новый чат", "Чати нав"))
            .setView(panel)
            .setNegativeButton(t("Закрыть", "Пӯшидан"), null)
            .create()
        search.doAfterTextChanged { render(it?.toString().orEmpty()) }
        render("")
        dialog.show()
        search.requestFocus()
        ChatClient.loadContacts { result ->
            result.onSuccess { serverContacts ->
                serverContacts.asReversed().forEach { contact ->
                    contacts.removeAll { it.second == contact.sipNumber }
                    contacts.add(0, contact.displayName to contact.sipNumber)
                }
                if (dialog.isShowing) render(search.text?.toString().orEmpty())
            }.onFailure { error ->
                if (dialog.isShowing) toast(error.message ?: t("Не удалось загрузить контакты чата", "Тамосҳои чат бор нашуданд"))
            }
        }
    }

    private fun chatContactRow(
        parent: LinearLayout,
        name: String,
        phone: String,
        action: () -> Unit
    ) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(7), dp(8), dp(7))
            setOnClickListener { action() }
        }
        row.addView(TextView(this).apply {
            text = avatarSymbols(name, phone)
            textSize = 14f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            background = rounded(blue, dp(21).toFloat())
        }, LinearLayout.LayoutParams(dp(42), dp(42)))
        val labels = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), 0, 0, 0)
        }
        heading(labels, name, 15, dark, 0)
        sub(labels, phone, 12, muted, 2)
        row.addView(labels, LinearLayout.LayoutParams(0, -2, 1f))
        row.addView(TextView(this).apply {
            text = "›"
            textSize = 25f
            setTextColor(muted)
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(dp(30), dp(42)))
        parent.addView(row, LinearLayout.LayoutParams(-1, dp(56)))
        parent.addView(View(this).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(-1, dp(1)).apply {
            leftMargin = dp(54)
        })
    }

    private fun showConversation(peerValue: String, refresh: Boolean = true) {
        val peer = runCatching { SipIdentity.requireValid(peerValue) }.getOrNull()
        if (peer == null) {
            toast(t("Некорректный номер абонента", "Рақами муштарӣ нодуруст аст"))
            return
        }
        homePage = HomePage.Chat
        currentChatPeer = peer
        if (ChatStore.markRead(chatOwner, peer)) ChatClient.markConversationRead(peer)
        if (refresh) ChatClient.syncConversation(peer)
        createShell()
        // Edge-to-edge layouts are not resized consistently by OEM keyboards.
        // This screen applies the IME inset itself so the composer always stays
        // immediately above the keyboard without a duplicated global offset.
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
        val body = screen(false).apply {
            setPadding(dp(10), 0, dp(10), 0)
            setBackgroundColor(TvoiceUi.color(this@MainActivity, R.color.tvoice_chat_background))
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, 0)
            setBackgroundColor(surface)
        }
        val back = ImageView(this).apply {
            setImageResource(R.drawable.ic_back)
            setColorFilter(blue)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            contentDescription = t("Назад", "Бозгашт")
            setOnClickListener { showChats() }
        }
        header.addView(back, LinearLayout.LayoutParams(dp(44), dp(54)))
        header.addView(TextView(this).apply {
            text = avatarSymbols("", peer)
            gravity = Gravity.CENTER
            TvoiceUi.style(this, TvoiceUi.SECONDARY_SP, Color.WHITE, TvoiceUi.semiBold())
            background = rounded(blue, dp(18).toFloat())
        }, LinearLayout.LayoutParams(dp(36), dp(36)))
        val headerText = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        heading(headerText, peer, TvoiceUi.LIST_TITLE_SP.toInt(), dark, 0).apply { typeface = TvoiceUi.semiBold(); maxLines = 1 }
        sub(headerText, if (ChatClient.isConnected) t("Онлайн", "Онлайн") else t("Не в сети", "Офлайн"), TvoiceUi.CAPTION_SP.toInt(), if (ChatClient.isConnected) green else muted, 2)
        header.addView(headerText, LinearLayout.LayoutParams(0, -2, 1f).apply { leftMargin = dp(9) })
        header.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_call)
            setColorFilter(blue)
            setPadding(dp(9), dp(9), dp(9), dp(9))
            contentDescription = t("Аудиозвонок", "Занги овозӣ")
            setOnClickListener { placeCall(peer) }
        }, LinearLayout.LayoutParams(dp(44), dp(44)))
        header.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_videocam)
            setColorFilter(blue)
            setPadding(dp(9), dp(9), dp(9), dp(9))
            contentDescription = t("Видеозвонок", "Занги видеоӣ")
            setOnClickListener { placeVideoCall(peer) }
        }, LinearLayout.LayoutParams(dp(44), dp(44)))
        header.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_more)
            setColorFilter(blue)
            setPadding(dp(11), dp(11), dp(11), dp(11))
            contentDescription = t("Меню", "Меню")
        }, LinearLayout.LayoutParams(dp(44), dp(44)))
        body.addView(header, LinearLayout.LayoutParams(-1, dp(54)))
        body.addView(View(this).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(-1, dp(1)))

        val messagesColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(2), dp(8), dp(2), dp(8))
        }
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            addView(messagesColumn)
        }
        activeConversationMessages = messagesColumn
        activeConversationScroll = scroll
        refreshOpenConversation()
        body.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))

        val composer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(3), 0, dp(3))
            setBackgroundColor(surface)
        }
        val attach = ImageView(this).apply {
            setImageResource(R.drawable.ic_add)
            setColorFilter(blue)
            setPadding(dp(11), dp(11), dp(11), dp(11))
            contentDescription = t("Фото или файл", "Акс ё файл")
            setOnClickListener { chooseChatAttachment(peer) }
        }
        composer.addView(attach, LinearLayout.LayoutParams(dp(44), dp(48)))
        val input = EditText(this).apply {
            hint = t("Сообщение...", "Паём...")
            TvoiceUi.style(this, TvoiceUi.BODY_SP, dark)
            setHintTextColor(muted)
            maxLines = 4
            setPadding(dp(12), 0, dp(10), 0)
            background = rounded(TvoiceUi.color(this@MainActivity, R.color.tvoice_search), dp(12).toFloat())
        }
        composer.addView(input, LinearLayout.LayoutParams(0, dp(48), 1f))
        val emoji = ImageView(this).apply {
            setImageResource(R.drawable.ic_emoji)
            setColorFilter(blue)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            contentDescription = t("Смайлики", "Табассумҳо")
            setOnClickListener { showEmojiPicker(input) }
        }
        composer.addView(emoji, LinearLayout.LayoutParams(dp(40), dp(48)))
        composer.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_camera)
            setColorFilter(blue)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            contentDescription = t("Отправить фото", "Ирсоли акс")
            setOnClickListener { chooseChatPhoto(peer) }
        }, LinearLayout.LayoutParams(dp(40), dp(48)))
        val send = ImageView(this).apply {
            setImageResource(R.drawable.ic_send)
            setColorFilter(Color.WHITE)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            background = rounded(blue, dp(24).toFloat())
            setOnClickListener {
                val text = input.text.toString().trim()
                if (text.isBlank()) return@setOnClickListener
                runCatching { sip.sendMessage(peer, text) }
                    .onSuccess { input.text.clear() }
                    .onFailure { toast(it.message ?: t("Ошибка отправки", "Хатои ирсол")) }
            }
        }
        composer.addView(send, LinearLayout.LayoutParams(dp(48), dp(48)).apply { leftMargin = dp(8) })
        body.addView(composer, LinearLayout.LayoutParams(-1, dp(54)))
        ViewCompat.setOnApplyWindowInsetsListener(composer) { view, insets ->
            val imeBottom = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            val systemBottom = insets.getInsetsIgnoringVisibility(
                WindowInsetsCompat.Type.systemBars()
            ).bottom
            val keyboardOffset = (imeBottom - systemBottom).coerceAtLeast(0)
            val params = view.layoutParams as LinearLayout.LayoutParams
            if (params.bottomMargin != keyboardOffset) {
                params.bottomMargin = keyboardOffset
                view.layoutParams = params
                scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
            }
            insets
        }
        input.setOnFocusChangeListener { _, focused ->
            if (focused) composer.post { ViewCompat.requestApplyInsets(composer) }
        }
        composer.post { ViewCompat.requestApplyInsets(composer) }
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun refreshOpenConversation(): Boolean {
        val peer = currentChatPeer ?: return false
        val messagesColumn = activeConversationMessages ?: return false
        val scroll = activeConversationScroll ?: return false
        messagesColumn.removeAllViews()
        var previousDay = ""
        ChatStore.messages(chatOwner, peer).forEach { message ->
            val day = SimpleDateFormat("dd.MM.yyyy", Locale.getDefault()).format(Date(message.timestamp))
            if (day != previousDay) {
                addChatDate(messagesColumn, message.timestamp)
                previousDay = day
            }
            addMessageBubble(messagesColumn, message)
        }
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
        return true
    }

    private fun addChatDate(parent: LinearLayout, timestamp: Long) {
        val label = TextView(this).apply {
            text = SimpleDateFormat("dd MMMM", Locale.getDefault()).format(Date(timestamp))
            TvoiceUi.style(this, TvoiceUi.CAPTION_SP, muted, TvoiceUi.medium())
            gravity = Gravity.CENTER
            setPadding(dp(10), dp(4), dp(10), dp(4))
            background = rounded(TvoiceUi.color(this@MainActivity, R.color.tvoice_search), dp(10).toFloat())
        }
        parent.addView(label, LinearLayout.LayoutParams(-2, dp(26)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(6); bottomMargin = dp(4) })
    }

    private fun showEmojiPicker(input: EditText) {
        val emojis = listOf(
            "😀", "😂", "😊", "😍", "🥰", "😎",
            "👍", "👏", "🙏", "💪", "👌", "🤝",
            "❤️", "🔥", "🎉", "✅", "☎️", "📞",
            "😢", "😮", "🤔", "😉", "🙂", "👋"
        )
        val grid = GridLayout(this).apply {
            columnCount = 6
            setPadding(dp(12), dp(8), dp(12), dp(8))
        }
        lateinit var dialog: AlertDialog
        emojis.forEach { value ->
            grid.addView(TextView(this).apply {
                text = value
                textSize = 25f
                gravity = Gravity.CENTER
                setOnClickListener {
                    val start = input.selectionStart.coerceAtLeast(0)
                    input.text.insert(start, value)
                    dialog.dismiss()
                }
            }, GridLayout.LayoutParams().apply {
                width = dp(48)
                height = dp(48)
            })
        }
        dialog = AlertDialog.Builder(this)
            .setTitle(t("Смайлики", "Табассумҳо"))
            .setView(grid)
            .setNegativeButton(t("Закрыть", "Пӯшидан"), null)
            .create()
        dialog.show()
    }

    private fun chooseChatAttachment(peer: String) {
        pendingChatAttachmentPeer = peer
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            type = "*/*"
            addCategory(Intent.CATEGORY_OPENABLE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "image/*",
                    "video/*",
                    "audio/*",
                    "application/pdf",
                    "text/*",
                    "application/msword",
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    "application/vnd.ms-excel",
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    "application/zip"
                )
            )
        }
        startActivityForResult(intent, REQUEST_CHAT_ATTACHMENT)
    }

    private fun chooseChatPhoto(peer: String) {
        pendingChatAttachmentPeer = peer
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            type = "image/*"
            addCategory(Intent.CATEGORY_OPENABLE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_CHAT_ATTACHMENT)
    }

    private fun addMessageBubble(parent: LinearLayout, message: ChatMessage) {
        val row = FrameLayout(this)
        val bubble = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(9), dp(7), dp(9), dp(7))
            background = rounded(
                TvoiceUi.color(this@MainActivity, if (message.incoming) R.color.tvoice_incoming_bubble else R.color.tvoice_outgoing_bubble),
                dp(14).toFloat()
            )
        }
        if (message.attachmentName != null) {
            addAttachmentPreview(bubble, message)
        } else {
            sub(bubble, message.text, TvoiceUi.BODY_SP.toInt(), if (message.incoming) dark else TvoiceUi.color(this, R.color.tvoice_outgoing_text), 0)
        }
        val status = if (message.incoming) "" else when (message.status) {
            "sending" -> "…"
            "failed" -> t("!  Нажмите для повтора", "!  Барои такрор зер кунед")
            "delivered" -> "✓✓"
            "read" -> "✓✓"
            else -> "✓"
        }
        val statusColor = when {
            message.incoming -> muted
            message.status == "read" -> dark
            else -> Color.rgb(210, 226, 255)
        }
        sub(
            bubble,
            "${formatTime(message.timestamp)}${if (status.isBlank()) "" else "  $status"}",
            10,
            statusColor,
            3
        ).gravity = Gravity.END
        if (message.status == "failed") {
            sub(
                bubble,
                message.deliveryError ?: t("Сообщение не доставлено", "Паём нарасид"),
                10,
                if (message.incoming) red else Color.rgb(255, 220, 220),
                3
            )
            if (message.attachmentName == null) {
                bubble.setOnClickListener {
                    runCatching { ChatClient.retryMessage(message) }
                        .onSuccess { refreshOpenConversation() }
                        .onFailure { toast(it.message ?: t("Повторная отправка не удалась", "Ирсоли такрорӣ нашуд")) }
                }
            }
        }
        row.addView(
            bubble,
            FrameLayout.LayoutParams(-2, -2, if (message.incoming) Gravity.START else Gravity.END).apply {
                leftMargin = if (message.incoming) 0 else dp(48)
                rightMargin = if (message.incoming) dp(48) else 0
            }
        )
        parent.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
    }

    private fun addAttachmentPreview(parent: LinearLayout, message: ChatMessage) {
        val foreground = if (message.incoming) dark else Color.WHITE
        val secondary = if (message.incoming) muted else Color.rgb(210, 226, 255)
        if (message.attachmentMime?.startsWith("image/") == true) {
            val preview = ImageView(this).apply {
                scaleType = ImageView.ScaleType.CENTER_CROP
                setImageResource(R.drawable.ic_chat)
                setColorFilter(secondary)
                setPadding(dp(55), dp(35), dp(55), dp(35))
                background = rounded(
                    if (message.incoming) page else Color.rgb(48, 94, 224),
                    dp(12).toFloat()
                )
                contentDescription = message.attachmentName
                setOnClickListener { openAttachment(message) }
            }
            parent.addView(preview, LinearLayout.LayoutParams(dp(210), dp(145)))
            if (message.attachmentId != null) {
                ChatClient.downloadAttachment(message) { result ->
                    result.onSuccess { file ->
                        val bitmap = decodeChatPreview(file)
                        if (bitmap != null) {
                            preview.clearColorFilter()
                            preview.setPadding(0, 0, 0, 0)
                            preview.setImageBitmap(bitmap)
                        }
                    }
                }
            }
        }
        val fileRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(7), 0, dp(2))
            setOnClickListener { openAttachment(message) }
        }
        fileRow.addView(ImageView(this).apply {
            setImageResource(if (message.attachmentMime?.startsWith("image/") == true) R.drawable.ic_camera else R.drawable.ic_file)
            setColorFilter(foreground)
            setPadding(dp(6), dp(6), dp(6), dp(6))
        }, LinearLayout.LayoutParams(dp(36), dp(36)))
        val fileText = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(7), 0, 0, 0) }
        heading(fileText, message.attachmentName.orEmpty(), TvoiceUi.BODY_SP.toInt(), foreground, 0).maxLines = 1
        sub(fileText, formatFileSize(message.attachmentSize), TvoiceUi.CAPTION_SP.toInt(), secondary, 2)
        fileRow.addView(fileText, LinearLayout.LayoutParams(0, -2, 1f))
        parent.addView(fileRow, LinearLayout.LayoutParams(dp(210), -2))
    }

    private fun decodeChatPreview(file: File) = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        var sample = 1
        while (bounds.outWidth / sample > 900 || bounds.outHeight / sample > 900) sample *= 2
        BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply { inSampleSize = sample })
    }.getOrNull()

    private fun openAttachment(message: ChatMessage) {
        toast(t("Загрузка файла…", "Боргирии файл…"))
        ChatClient.downloadAttachment(message) { result ->
            result.onSuccess { file ->
                val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, message.attachmentMime ?: "*/*")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                runCatching { startActivity(intent) }
                    .onFailure { toast(t("Нет приложения для открытия файла", "Барнома барои кушодани файл нест")) }
            }.onFailure { error ->
                toast(error.message ?: t("Не удалось загрузить файл", "Боргирии файл нашуд"))
            }
        }
    }

    private fun formatFileSize(size: Long): String = when {
        size <= 0 -> t("Загрузка…", "Боргирӣ…")
        size < 1024 -> "$size Б"
        size < 1024 * 1024 -> "${size / 1024} КБ"
        else -> String.format(Locale.getDefault(), "%.1f МБ", size / 1024.0 / 1024.0)
    }

    private fun showAccount() = showProfile()

    private fun showProfile() {
        homePage = HomePage.Profile
        currentChatPeer = null
        createShell()
        val body = screen()
        pageTitle(body, t("Аккаунт", "Ҳисоб"))

        val profile = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(12), 0, dp(14))
        }
        val photoWrap = FrameLayout(this).apply {
            background = rounded(blue, dp(32).toFloat())
            isClickable = true
            isFocusable = true
            setOnClickListener { choosePhoto() }
        }
        profileImage = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            if (profileUri != null) setImageURI(profileUri) else {
                setImageResource(R.drawable.ic_account)
                setColorFilter(Color.WHITE)
                setPadding(dp(16), dp(16), dp(16), dp(16))
            }
            contentDescription = t("Изменить фото", "Иваз кардани акс")
        }
        photoWrap.addView(profileImage, FrameLayout.LayoutParams(-1, -1))
        profile.addView(photoWrap, LinearLayout.LayoutParams(dp(64), dp(64)))
        val identity = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), 0, 0, 0)
        }
        heading(identity, ownNumber, 20, dark, 0).typeface = TvoiceUi.semiBold()
        sub(identity, t("● Подключено", "● Пайваст"), TvoiceUi.SECONDARY_SP.toInt(), green, 4)
        sub(identity, if (ChatClient.isConnected) t("Чат подключён", "Чат пайваст") else ChatClient.stateMessage.ifBlank { t("Подключение чата…", "Пайвастшавии чат…") }, TvoiceUi.CAPTION_SP.toInt(), muted, 3)
        profile.addView(identity, LinearLayout.LayoutParams(0, -2, 1f))
        body.addView(profile, LinearLayout.LayoutParams(-1, dp(92)))

        sectionLabel(body, t("Аккаунты", "Ҳисобҳо"))
        val numbers = (TvoiceRuntime.accountUsernames() + ownNumber)
            .filter { it.isNotBlank() }
            .distinct()
        numbers.forEach { number ->
            profileSettingRow(
                body,
                R.drawable.ic_account,
                number,
                if (number == ownNumber) t("Активный", "Фаъол") else t("Переключить", "Гузариш")
            ) {
                if (number != ownNumber) {
                    runCatching { sip.selectAccount(number) }
                        .onSuccess { ownNumber = number; showProfile() }
                        .onFailure { toast(it.message ?: t("Ошибка аккаунта", "Хатои ҳисоб")) }
                }
            }
        }
        profileSettingRow(body, R.drawable.ic_add, t("Добавить аккаунт", "Илова кардани ҳисоб"), "") { showAddAccountDialog() }

        sectionLabel(body, t("Настройки", "Танзимот"))
        profileSettingRow(body, R.drawable.ic_chat, t("Уведомления", "Огоҳиномаҳо"), notificationSettingsSummary()) { showNotificationSettingsDialog() }
        profileSettingRow(body, R.drawable.ic_speaker, t("Звук и устройства", "Овоз ва дастгоҳҳо"), soundSettingsSummary()) { showSoundSettingsDialog() }
        profileSettingRow(body, R.drawable.ic_contacts, t("Язык", "Забон"), if (isTajik) "Тоҷикӣ" else "Русский") { showLanguageDialog() }
        profileSettingRow(body, R.drawable.ic_tvoice, t("Оформление", "Намуди зоҳирӣ"), themeModeLabel()) { showThemeDialog() }
        profileSettingRow(body, R.drawable.ic_info, t("SIP-сервер", "Сервери SIP"), "185.177.2.115 • UDP") { }

        sectionLabel(body, t("О приложении", "Дар бораи барнома"))
        sub(body, t(
            "Tvoice — звонки и сообщения между абонентами вашего SIP-сервера.",
            "Tvoice — зангҳо ва паёмҳо байни муштариёни сервери SIP."
        ), TvoiceUi.SECONDARY_SP.toInt(), muted, 4)
        sub(body, appVersionLabel(), TvoiceUi.SECONDARY_SP.toInt(), blue, 8)
        sub(body, "Developed by Шогирдои Малем", TvoiceUi.SECONDARY_SP.toInt(), dark, 5).typeface = TvoiceUi.semiBold()
        compactButton(body, t("Выйти из аккаунта", "Баромадан аз ҳисоб"), red) {
            sip.logout()
            stopService(Intent(this, TvoiceCallService::class.java))
            ownNumber = ""
            pendingPassword = ""
            showLogin()
        }
    }

    private fun profileSettingRow(parent: LinearLayout, icon: Int, title: String, value: String, action: () -> Unit) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, 0)
            background = TvoiceUi.ripple(this@MainActivity, surface, 0)
            setOnClickListener { action() }
        }
        row.addView(ImageView(this).apply {
            setImageResource(icon)
            setColorFilter(blue)
            setPadding(dp(11), dp(11), dp(11), dp(11))
        }, LinearLayout.LayoutParams(dp(44), dp(44)))
        row.addView(TextView(this).apply {
            text = title
            TvoiceUi.style(this, TvoiceUi.BODY_SP, dark, TvoiceUi.medium())
            gravity = Gravity.CENTER_VERTICAL
        }, LinearLayout.LayoutParams(0, -1, 1f).apply { leftMargin = dp(6) })
        if (value.isNotBlank()) {
            row.addView(TextView(this).apply {
                text = value
                maxLines = 1
                TvoiceUi.style(this, TvoiceUi.SECONDARY_SP, muted)
                gravity = Gravity.CENTER_VERTICAL or Gravity.END
            }, LinearLayout.LayoutParams(-2, -1).apply { rightMargin = dp(2) })
        }
        row.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_chevron_right)
            setColorFilter(muted)
            setPadding(dp(13), dp(13), dp(13), dp(13))
        }, LinearLayout.LayoutParams(dp(44), dp(44)))
        parent.addView(row, LinearLayout.LayoutParams(-1, dp(54)))
        parent.addView(View(this).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(-1, dp(1)).apply { leftMargin = dp(50) })
    }

    private fun showAccountDrawer() {
        if (!::rootContainer.isInitialized) return
        if (activeDrawerOverlay != null) return
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
        val numbers = (TvoiceRuntime.accountUsernames() + ownNumber).filter { it.isNotBlank() }.distinct()
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
            themeModeLabel(),
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
        sub(scrollBody, appVersionLabel(), 12, blue, 7)
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
        activeDrawerOverlay = overlay
        activeDrawerPanel = panel
        panel.post { panel.animate().translationX(0f).setDuration(220).start() }
    }

    private fun closeDrawer(overlay: View, panel: View) {
        if (activeDrawerOverlay === overlay) {
            activeDrawerOverlay = null
            activeDrawerPanel = null
        }
        panel.animate().translationX(panel.width.toFloat()).setDuration(180).withEndAction {
            (overlay.parent as? ViewGroup)?.removeView(overlay)
        }.start()
    }

    private fun closeActiveDrawer(): Boolean {
        val overlay = activeDrawerOverlay ?: return false
        val panel = activeDrawerPanel ?: return false
        closeDrawer(overlay, panel)
        return true
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
        val values = arrayOf(
            t("Системная", "Системавӣ"),
            t("Светлая", "Равшан"),
            t("Тёмная", "Торик")
        )
        val selected = when (themeMode) {
            "light" -> 1
            "dark" -> 2
            else -> 0
        }
        AlertDialog.Builder(this)
            .setTitle(t("Оформление", "Намуди зоҳирӣ"))
            .setSingleChoiceItems(values, selected) { dialog, which ->
                val value = when (which) {
                    1 -> "light"
                    2 -> "dark"
                    else -> "system"
                }
                preferences.edit().putString("theme", value).apply()
                dialog.dismiss()
                recreate()
            }
            .show()
    }

    private fun themeModeLabel(): String = when (themeMode) {
        "light" -> t("Светлая", "Равшан")
        "dark" -> t("Тёмная", "Торик")
        else -> t("Системная", "Системавӣ")
    }

    private fun appVersionLabel(): String =
        "Tvoice ${BuildConfig.VERSION_NAME} • SIP Core 1.8 • Chat Core 0.4"

    private fun showIncomingCall(remote: String) {
        callUiMinimized = false
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
        sub(
            body,
            if (sip.isVideoCall) t("Входящий видеозвонок", "Занги видеоии воридотӣ") else t("Входящий звонок", "Занги воридотӣ"),
            17,
            muted,
            10
        ).gravity = Gravity.CENTER
        body.addView(Space(this), LinearLayout.LayoutParams(1, 0, 1f))

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        actions.addView(incomingAction(R.drawable.ic_call_end, red, t("Отклонить", "Рад кардан")) { sip.hangup() }, LinearLayout.LayoutParams(0, dp(126), 1f))
        actions.addView(incomingAction(R.drawable.ic_call, green, t("Ответить", "Ҷавоб додан")) { answerIncomingCall() }, LinearLayout.LayoutParams(0, dp(126), 1f))
        body.addView(actions, LinearLayout.LayoutParams(-1, dp(126)))
        notifyIncomingScreenVisible()
    }

    private fun notifyIncomingScreenVisible() {
        startService(
            Intent(this, TvoiceCallService::class.java)
                .setAction(TvoiceCallService.ACTION_INCOMING_SCREEN_VISIBLE)
        )
    }

    private fun answerIncomingCall() {
        startService(
            Intent(this, TvoiceCallService::class.java)
                .setAction(TvoiceCallService.ACTION_ANSWER)
        )
    }

    private fun showCall(remote: String, state: String) {
        if (sip.isVideoCall) {
            showVideoCall(remote, state)
            return
        }
        createShell(false)
        showingCallScreen = true
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
        val callHeader = FrameLayout(this).apply {
            addView(TextView(this@MainActivity).apply {
                text = "Tvoice"
                textSize = 16f
                setTextColor(blue)
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
            }, FrameLayout.LayoutParams(-1, -1))
            addView(ImageView(this@MainActivity).apply {
                setImageResource(R.drawable.ic_minimize)
                setColorFilter(blue)
                setPadding(dp(10), dp(10), dp(10), dp(10))
                contentDescription = t("Свернуть звонок", "Пӯшидани равзанаи занг")
                background = rounded(surface, dp(20).toFloat(), line, 1)
                setOnClickListener { minimizeCall() }
            }, FrameLayout.LayoutParams(dp(42), dp(42), Gravity.END or Gravity.CENTER_VERTICAL))
        }
        body.addView(callHeader, LinearLayout.LayoutParams(-1, dp(44)))
        if (sip.isVideoCall) {
            body.addView(
                videoCanvas(remote),
                LinearLayout.LayoutParams(-1, dp(if (veryCompact) 190 else if (compact) 230 else 280)).apply {
                    topMargin = dp(8)
                }
            )
        } else {
            val avatar = TextView(this).apply {
                text = avatarSymbols("", remote)
                textSize = if (veryCompact) 22f else 26f
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
                typeface = Typeface.DEFAULT_BOLD
                background = rounded(blue, dp(primarySize / 2).toFloat())
            }
            body.addView(avatar, LinearLayout.LayoutParams(dp(primarySize), dp(primarySize)))
        }
        heading(body, remote, TvoiceUi.CALL_NUMBER_SP.toInt(), dark, if (compact) 14 else 20).apply {
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
        }
        sub(body, state, if (veryCompact) 14 else 16, if (isDarkTheme) cyan else Color.rgb(47, 107, 219), 6).apply {
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
        }
        val duration = sub(body, "", if (veryCompact) 17 else 20, dark, 5).apply {
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
            typeface = Typeface.MONOSPACE
            visibility = if (TvoiceRuntime.callConnectedAtMillis == null) View.GONE else View.VISIBLE
        }
        if (duration.visibility == View.VISIBLE) startCallTimer(duration)
        val spacer = Space(this); body.addView(spacer, LinearLayout.LayoutParams(1, 0, 1f))
        val keypad = callKeypad(compact).apply { visibility = View.GONE }
        body.addView(keypad, LinearLayout.LayoutParams(-1, dp(keypadHeight)))
        val firstRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        firstRow.addView(toggleCallControl(
            R.drawable.ic_mic,
            R.drawable.ic_mic_off,
            t("Микрофон", "Микрофон"),
            compact,
            initialSelected = sip.isMuted(),
            selectedBackground = if (isDarkTheme) Color.rgb(71, 85, 105) else Color.rgb(226, 232, 240),
            selectedIconColor = if (isDarkTheme) Color.rgb(203, 213, 225) else Color.rgb(71, 85, 105)
        ) { sip.toggleMute() }, LinearLayout.LayoutParams(0, dp(rowHeight), 1f))
        firstRow.addView(toggleCallControl(R.drawable.ic_dialpad, R.drawable.ic_dialpad, t("Клавиатура", "Тугмаҳо"), compact) { keypad.visibility = if (keypad.visibility == View.VISIBLE) View.GONE else View.VISIBLE; keypad.visibility == View.VISIBLE }, LinearLayout.LayoutParams(0, dp(rowHeight), 1f))
        firstRow.addView(toggleCallControl(
            R.drawable.ic_speaker,
            R.drawable.ic_speaker,
            t("Динамик", "Баландгӯяк"),
            compact,
            initialSelected = sip.isSpeakerEnabled(),
            selectedBackground = if (isDarkTheme) Color.rgb(49, 78, 132) else Color.rgb(219, 232, 255),
            selectedIconColor = if (isDarkTheme) Color.rgb(147, 197, 253) else blue
        ) { sip.toggleSpeaker() }, LinearLayout.LayoutParams(0, dp(rowHeight), 1f))
        body.addView(firstRow, LinearLayout.LayoutParams(-1, dp(rowHeight)))
        val secondRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        secondRow.addView(toggleCallControl(R.drawable.ic_pause, R.drawable.ic_play, t("Удержание", "Нигоҳдорӣ"), compact) { sip.toggleHold() }, LinearLayout.LayoutParams(0, dp(rowHeight), 1f))
        if (sip.isVideoCall) {
            secondRow.addView(
                toggleCallControl(
                    R.drawable.ic_videocam,
                    R.drawable.ic_videocam,
                    t("Камера", "Камера"),
                    compact,
                    initialSelected = sip.isVideoCameraEnabled()
                ) {
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 16)
                        false
                    } else sip.toggleVideoCamera().also { refreshVideoServiceType() }
                },
                LinearLayout.LayoutParams(0, dp(rowHeight), 1f)
            )
            secondRow.addView(
                toggleCallControl(
                    R.drawable.ic_switch_camera,
                    R.drawable.ic_switch_camera,
                    t("Повернуть", "Иваз"),
                    compact
                ) {
                    val switched = sip.switchVideoCamera()
                    if (!switched) toast(t("Вторая камера не найдена", "Камераи дуюм ёфт нашуд"))
                    false
                },
                LinearLayout.LayoutParams(0, dp(rowHeight), 1f)
            )
        }
        if (sip.supportsConference()) {
            secondRow.addView(
                toggleCallControl(
                    R.drawable.ic_group_add,
                    R.drawable.ic_group_add,
                    t("Конференция", "Конфронс"),
                    compact
                ) { false },
                LinearLayout.LayoutParams(0, dp(rowHeight), 1f)
            )
        }
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

    private fun showVideoCall(remote: String, state: String) {
        createShell(false)
        showingCallScreen = true
        videoControlsVisible = true
        val frame = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            isClickable = true
        }
        content.removeAllViews()
        content.addView(frame, FrameLayout.LayoutParams(-1, -1))

        val remoteView = SurfaceView(this).apply {
            contentDescription = t("Видео собеседника $remote", "Видеои ҳамсуҳбат $remote")
            // Portrait-first fallback. Negotiated CVO packets replace this value.
            rotation = 90f
        }
        videoRemoteView = remoteView
        frame.addView(remoteView, FrameLayout.LayoutParams(-1, -1))
        remoteView.post { applyRemoteVideoRotation(90) }
        remoteView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) { videoRemoteHolder = holder; attachVideoSurfaces() }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) { videoRemoteHolder = holder; attachVideoSurfaces() }
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (videoRemoteHolder === holder) videoRemoteHolder = null
                attachVideoSurfaces()
            }
        })

        val topOverlay = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP
            setPadding(dp(8), dp(8), dp(8), dp(24))
            background = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(Color.argb(205, 0, 0, 0), Color.argb(110, 0, 0, 0), Color.TRANSPARENT)
            )
        }
        topOverlay.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_back)
            setColorFilter(Color.WHITE)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            contentDescription = t("Свернуть звонок", "Пӯшидани равзанаи занг")
            setOnClickListener { minimizeCall() }
        }, LinearLayout.LayoutParams(dp(48), dp(48)))
        val callInfo = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(2), 0, 0)
        }
        sub(callInfo, t("Tvoice • защищённый видеозвонок", "Tvoice • занги видеоии ҳифзшуда"), 10, Color.argb(220, 255, 255, 255), 0).apply {
            gravity = Gravity.CENTER
        }
        heading(callInfo, remote, 20, Color.WHITE, 4).apply {
            gravity = Gravity.CENTER
            typeface = TvoiceUi.semiBold()
        }
        val timer = sub(callInfo, state, 12, Color.WHITE, 3).apply { gravity = Gravity.CENTER }
        startCallTimer(timer, state)
        topOverlay.addView(callInfo, LinearLayout.LayoutParams(0, -2, 1f))
        topOverlay.addView(Space(this), LinearLayout.LayoutParams(dp(48), dp(48)))
        frame.addView(topOverlay, FrameLayout.LayoutParams(-1, dp(126), Gravity.TOP))

        val localWidth = (resources.configuration.screenWidthDp * 0.27f).toInt().coerceIn(86, 124)
        val localHeight = (localWidth * 4f / 3f).toInt()
        val localView = SurfaceView(this).apply {
            setZOrderMediaOverlay(true)
            // Camera2 receives this Surface as a second recording target. Its buffer
            // must match the encoder stream, independent of the small on-screen view.
            holder.setFixedSize(1280, 720)
            rotation = sip.videoCameraRotationDegrees().toFloat()
            scaleX = if (sip.isFrontVideoCamera()) -1f else 1f
            clipToOutline = true
            background = rounded(Color.rgb(20, 27, 40), dp(14).toFloat(), Color.WHITE, 1)
            contentDescription = t("Перетаскиваемый предпросмотр камеры", "Пешнамоиши камера")
        }
        videoLocalView = localView
        frame.addView(localView, FrameLayout.LayoutParams(dp(localWidth), dp(localHeight), Gravity.END or Gravity.TOP).apply {
            topMargin = dp(116)
            rightMargin = dp(14)
        })
        localView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) { videoLocalHolder = holder; attachVideoSurfaces() }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) { videoLocalHolder = holder; attachVideoSurfaces() }
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (videoLocalHolder === holder) videoLocalHolder = null
                attachVideoSurfaces()
            }
        })

        var touchOffsetX = 0f
        var touchOffsetY = 0f
        localView.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                android.view.MotionEvent.ACTION_DOWN -> {
                    touchOffsetX = event.rawX - view.x
                    touchOffsetY = event.rawY - view.y
                    showVideoControls(topOverlay, null)
                    true
                }
                android.view.MotionEvent.ACTION_MOVE -> {
                    val maxX = (frame.width - view.width).coerceAtLeast(0).toFloat()
                    val maxY = (frame.height - view.height).coerceAtLeast(0).toFloat()
                    view.x = (event.rawX - touchOffsetX).coerceIn(0f, maxX)
                    view.y = (event.rawY - touchOffsetY).coerceIn(0f, maxY)
                    true
                }
                android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL -> {
                    scheduleVideoControlsHide(topOverlay, null)
                    true
                }
                else -> false
            }
        }

        val bottomOverlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(18), dp(36), dp(18), dp(18))
            background = GradientDrawable(
                GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(Color.argb(220, 0, 0, 0), Color.argb(120, 0, 0, 0), Color.TRANSPARENT)
            )
        }
        bottomOverlay.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_call_end)
            setColorFilter(Color.WHITE)
            setPadding(dp(17), dp(17), dp(17), dp(17))
            background = rounded(red, dp(29).toFloat())
            elevation = dp(5).toFloat()
            contentDescription = t("Завершить видеозвонок", "Анҷоми занги видеоӣ")
            setOnClickListener { sip.hangup() }
        }, LinearLayout.LayoutParams(dp(58), dp(58)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            bottomMargin = dp(24)
        })

        val controlsRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        controlsRow.addView(videoCircleAction(R.drawable.ic_switch_camera, R.drawable.ic_switch_camera, t("Переключить камеру", "Ивази камера"), false) {
            val switched = sip.switchVideoCamera()
            if (switched) {
                localView.rotation = sip.videoCameraRotationDegrees().toFloat()
                localView.scaleX = if (sip.isFrontVideoCamera()) -1f else 1f
            } else toast(t("Вторая камера не найдена", "Камераи дуюм ёфт нашуд"))
            false
        }, LinearLayout.LayoutParams(0, dp(52), 1f))
        controlsRow.addView(videoCircleAction(R.drawable.ic_videocam_off, R.drawable.ic_videocam, t("Включить или выключить камеру", "Фаъол ё хомӯш кардани камера"), sip.isVideoCameraEnabled()) {
            sip.toggleVideoCamera().also { refreshVideoServiceType() }
        }, LinearLayout.LayoutParams(0, dp(52), 1f))
        controlsRow.addView(videoCircleAction(R.drawable.ic_speaker, R.drawable.ic_speaker, t("Динамик", "Баландгӯяк"), sip.isSpeakerEnabled()) {
            sip.toggleSpeaker()
        }, LinearLayout.LayoutParams(0, dp(52), 1f))
        controlsRow.addView(videoCircleAction(R.drawable.ic_mic, R.drawable.ic_mic_off, t("Микрофон", "Микрофон"), sip.isMuted()) {
            sip.toggleMute()
        }, LinearLayout.LayoutParams(0, dp(52), 1f))
        bottomOverlay.addView(controlsRow, LinearLayout.LayoutParams(-1, dp(52)))
        frame.addView(bottomOverlay, FrameLayout.LayoutParams(-1, dp(212), Gravity.BOTTOM))

        frame.setOnClickListener {
            if (videoControlsVisible) scheduleVideoControlsHide(topOverlay, bottomOverlay)
            else showVideoControls(topOverlay, bottomOverlay)
        }
        showVideoControls(topOverlay, bottomOverlay)
    }

    private fun videoCircleAction(
        icon: Int,
        activeIcon: Int,
        label: String,
        initialSelected: Boolean,
        action: () -> Boolean
    ): FrameLayout = FrameLayout(this).apply {
        var selectedState = initialSelected
        val image = ImageView(this@MainActivity).apply {
            contentDescription = label
            fun render() {
                setImageResource(if (selectedState) activeIcon else icon)
                setColorFilter(Color.WHITE)
                background = rounded(
                    if (selectedState) Color.argb(190, 10, 132, 255) else Color.argb(90, 255, 255, 255),
                    dp(24).toFloat(),
                    Color.argb(80, 255, 255, 255),
                    1
                )
            }
            setPadding(dp(13), dp(13), dp(13), dp(13))
            render()
            setOnClickListener {
                selectedState = action()
                render()
                videoControlsHideTask?.let { task ->
                    uiHandler.removeCallbacks(task)
                    uiHandler.postDelayed(task, 2_800L)
                }
            }
        }
        addView(image, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.CENTER))
    }

    private fun showVideoControls(top: View?, bottom: View?) {
        videoControlsHideTask?.let(uiHandler::removeCallbacks)
        listOfNotNull(top, bottom).forEach { view ->
            view.visibility = View.VISIBLE
            view.animate().alpha(1f).setDuration(150).start()
        }
        videoControlsVisible = true
        scheduleVideoControlsHide(top, bottom)
    }

    private fun scheduleVideoControlsHide(top: View?, bottom: View?) {
        videoControlsHideTask?.let(uiHandler::removeCallbacks)
        val task = Runnable {
            listOfNotNull(top, bottom).forEach { view ->
                view.animate().alpha(0f).setDuration(180).withEndAction { view.visibility = View.INVISIBLE }.start()
            }
            videoControlsVisible = false
        }
        videoControlsHideTask = task
        uiHandler.postDelayed(task, 2_800L)
    }

    private fun videoCanvas(remote: String): FrameLayout {
        val frame = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            clipToOutline = true
            background = rounded(Color.BLACK, dp(18).toFloat())
        }
        val remoteView = SurfaceView(this).apply {
            contentDescription = t("Видео собеседника $remote", "Видеои ҳамсуҳбат $remote")
            holder.setFixedSize(640, 480)
            rotation = 90f
        }
        frame.addView(remoteView, FrameLayout.LayoutParams(-1, -1))
        remoteView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                videoRemoteHolder = holder
                attachVideoSurfaces()
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                videoRemoteHolder = holder
                attachVideoSurfaces()
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (videoRemoteHolder === holder) videoRemoteHolder = null
                attachVideoSurfaces()
            }
        })
        val localView = SurfaceView(this).apply {
            setZOrderMediaOverlay(true)
            contentDescription = t("Предпросмотр камеры", "Пешнамоиши камера")
            holder.setFixedSize(1280, 720)
        }
        frame.addView(
            localView,
            FrameLayout.LayoutParams(dp(84), dp(112), Gravity.END or Gravity.BOTTOM).apply {
                rightMargin = dp(10)
                bottomMargin = dp(10)
            }
        )
        localView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                videoLocalHolder = holder
                attachVideoSurfaces()
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                videoLocalHolder = holder
                attachVideoSurfaces()
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (videoLocalHolder === holder) videoLocalHolder = null
                attachVideoSurfaces()
            }
        })
        return frame
    }

    private fun attachVideoSurfaces() {
        if (!sip.isVideoCall) return
        sip.setVideoSurfaces(
            videoLocalHolder?.surface?.takeIf { it.isValid },
            videoRemoteHolder?.surface?.takeIf { it.isValid }
        )
    }

    private fun applyRemoteVideoRotation(degrees: Int) {
        val view = videoRemoteView ?: return
        val normalized = ((degrees % 360) + 360) % 360
        view.post {
            view.rotation = normalized.toFloat()
            val quarterTurn = normalized == 90 || normalized == 270
            val scale = if (quarterTurn && view.width > 0 && view.height > 0) {
                maxOf(view.width.toFloat() / view.height, view.height.toFloat() / view.width)
            } else 1f
            view.scaleX = scale
            view.scaleY = scale
        }
    }

    private fun applyLocalVideoRotation(degrees: Int) {
        val view = videoLocalView ?: return
        val normalized = ((degrees % 360) + 360) % 360
        view.post {
            view.rotation = normalized.toFloat()
            view.scaleX = if (sip.isFrontVideoCamera()) -1f else 1f
        }
    }

    private fun refreshVideoServiceType() {
        startService(
            Intent(this, TvoiceCallService::class.java)
                .setAction(TvoiceCallService.ACTION_VIDEO_STATE_CHANGED)
        )
    }

    override fun onRegistration(state: RegistrationState, message: String) = runOnUiThread {
        when (state) {
            RegistrationState.Ok -> {
                ownNumber = TvoiceRuntime.activeUsername
                if (addingAccount) {
                    accountNumbers.add(pendingAddedNumber); ownNumber = pendingAddedNumber; addingAccount = false; showAccount()
                } else {
                    if (ownNumber.isNotEmpty() && ownNumber !in accountNumbers) accountNumbers.add(ownNumber)
                    if (!isOngoingCall() && TvoiceRuntime.callState != CallState.IncomingReceived) {
                        intent.getStringExtra(EXTRA_OPEN_CHAT)?.let(::showConversation) ?: showCalls()
                    }
                }
            }
            RegistrationState.Failed -> if (ownNumber.isNotEmpty()) {
                val fatal = message.contains("логин", true) ||
                    message.contains("пароль", true) ||
                    message.startsWith("SIP 401") ||
                    message.startsWith("SIP 403") ||
                    message.startsWith("SIP 404")
                toast(t("Нет связи: $message", "Пайваст нест: $message"))
                if (fatal && addingAccount) {
                    addingAccount = false
                    pendingAddedNumber = ""
                    ownNumber = TvoiceRuntime.activeUsername
                    accountNumbers.clear()
                    accountNumbers.addAll(TvoiceRuntime.accountUsernames())
                    showAccount()
                } else if (fatal) showLogin() else showConnecting()
            }
            RegistrationState.Cleared -> if (ownNumber.isNotEmpty()) showLogin()
            else -> Unit
        }
    }

    override fun onCall(state: CallState, remote: String, message: String) = runOnUiThread {
        if (state == CallState.IncomingReceived) {
            beginHistory(remote, "Входящий")
        }
        if (state == CallState.Connected || state == CallState.StreamsRunning) {
            callHistoryTracker.markConnected(System.currentTimeMillis())
        }
        if (state == CallState.End || state == CallState.Error || state == CallState.Released) {
            finishHistory()
        }
        if (!TvoiceRuntime.isMainUiVisible) return@runOnUiThread
        if (state == CallState.StreamsRunning && message.startsWith("Видео:")) {
            val remoteRotation = message.substringAfter("Видео:rotation=", "").toIntOrNull()
            val localRotation = message.substringAfter("Видео:local-rotation=", "").toIntOrNull()
            when {
                remoteRotation != null -> applyRemoteVideoRotation(remoteRotation)
                localRotation != null -> applyLocalVideoRotation(localRotation)
                else -> toast(message)
            }
            return@runOnUiThread
        }
        when (state) {
            CallState.IncomingReceived -> {
                callUiMinimized = false
                showIncomingCall(remote)
            }
            CallState.OutgoingInit -> {
                if (!callUiMinimized) showCall(remote, t("Вызов…", "Занг…"))
            }
            CallState.OutgoingProgress, CallState.OutgoingRinging -> {
                // INVITE progress events arrive within milliseconds. Rebuilding the
                // complete hierarchy for each one made the call window visibly jump.
                if (!callUiMinimized && !showingCallScreen) showCall(remote, t("Вызов…", "Занг…"))
            }
            CallState.Connected -> {
                if (!callUiMinimized) showCall(remote, t("Соединено", "Пайваст"))
            }
            CallState.StreamsRunning -> {
                if (!callUiMinimized && !showingCallScreen) showCall(remote, t("Соединено", "Пайваст"))
            }
            CallState.Paused -> {
                if (!callUiMinimized) showCall(remote, t("Удержание", "Нигоҳдорӣ"))
            }
            CallState.Error -> {
                toast("Ошибка звонка: $message")
                val wasMinimized = callUiMinimized
                callUiMinimized = false
                if (showingCallScreen || !wasMinimized) showCalls() else dismissActiveCallBanner()
            }
            CallState.End -> {
                if (message.isNotBlank()) toast(message)
                val wasMinimized = callUiMinimized
                callUiMinimized = false
                if (showingCallScreen || !wasMinimized) showCalls() else dismissActiveCallBanner()
            }
            CallState.Released -> {
                callUiMinimized = false
                dismissActiveCallBanner()
            }
            else -> Unit
        }
    }

    override fun onMessage(state: MessageState, remote: String, text: String, message: String) = runOnUiThread {
        val peer = SipIdentity.normalize(remote)
        if (currentChatPeer == peer && TvoiceRuntime.isMainUiVisible) {
            refreshOpenConversation()
        } else if (state == MessageState.Received && TvoiceRuntime.isMainUiVisible) {
            toast(t("Новое сообщение от $peer", "Паёми нав аз $peer"))
            if (homePage == HomePage.Chat) showChats()
        } else if (state == MessageState.Error && TvoiceRuntime.isMainUiVisible) {
            toast(t("Не удалось отправить: $message", "Ирсол нашуд: $message"))
        }
    }

    override fun onChatState(connected: Boolean, message: String) = runOnUiThread {
        if (!TvoiceRuntime.isMainUiVisible) return@runOnUiThread
        if (!connected && message.contains("не синхронизирован", true)) toast(message)
        when (homePage) {
            HomePage.Chat -> if (currentChatPeer == null) showChats(refresh = false)
            HomePage.Profile -> showProfile()
            else -> Unit
        }
    }

    override fun onChatSync(peer: String?) = runOnUiThread {
        if (!TvoiceRuntime.isMainUiVisible || homePage != HomePage.Chat) return@runOnUiThread
        val openedPeer = currentChatPeer
        if (openedPeer != null && (peer == null || peer == openedPeer)) {
            refreshOpenConversation()
        } else if (openedPeer == null) {
            showChats(refresh = false)
        }
    }

    override fun onChatMessage(message: ChatMessage) = runOnUiThread {
        if (!TvoiceRuntime.isMainUiVisible || !message.incoming) return@runOnUiThread
        if (currentChatPeer != message.peer) {
            toast(t("Новое сообщение от ${message.peer}", "Паёми нав аз ${message.peer}"))
        }
    }

    override fun onIncomingVideoCall(invite: ChatClient.VideoCallInvite) = runOnUiThread {
        if (!TvoiceRuntime.isMainUiVisible) return@runOnUiThread
        if (TvoiceRuntime.callState !in setOf(CallState.Idle, CallState.End, CallState.Released)) {
            ChatClient.rejectVideoCall(invite.callId)
            return@runOnUiThread
        }
        startActivity(
            VideoCallActivity.incomingIntent(this, invite)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        )
    }

    private fun navItem(icon: Int, label: String, selected: Boolean, action: () -> Unit) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            isClickable = true
            isFocusable = true
            foreground = TvoiceUi.ripple(this@MainActivity, Color.TRANSPARENT, 12)
            val i = ImageView(this@MainActivity).apply { setImageResource(icon); setColorFilter(if (selected) blue else muted); setPadding(dp(2), dp(2), dp(2), dp(2)) }
            val l = TextView(this@MainActivity).apply {
                text = label
                TvoiceUi.style(this, TvoiceUi.CAPTION_SP, if (selected) blue else muted, if (selected) TvoiceUi.medium() else TvoiceUi.regular())
                gravity = Gravity.CENTER
            }
            addView(i, LinearLayout.LayoutParams(dp(24), dp(24)))
            addView(l, LinearLayout.LayoutParams(-1, dp(20)).apply { topMargin = dp(2) })
            setOnClickListener { action() }
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
        if (requestCode == REQUEST_CHAT_ATTACHMENT && resultCode == RESULT_OK) {
            val peer = pendingChatAttachmentPeer
            pendingChatAttachmentPeer = ""
            data?.data?.let { uri ->
                runCatching {
                    contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                runCatching { ChatClient.sendAttachment(peer, uri) }
                    .onSuccess { showConversation(peer, refresh = false) }
                    .onFailure { toast(it.message ?: t("Не удалось отправить файл", "Ирсоли файл нашуд")) }
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

    private fun toggleCallControl(
        icon: Int,
        activeIcon: Int,
        label: String,
        compact: Boolean,
        initialSelected: Boolean = false,
        selectedBackground: Int = blue,
        selectedIconColor: Int = Color.WHITE,
        action: () -> Boolean
    ) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
        val controlSize = if (compact) 52 else 60
        val iconPadding = if (compact) 14 else 16
        val image = ImageView(this@MainActivity).apply {
            fun display(selected: Boolean) {
                setImageResource(if (selected) activeIcon else icon)
                setColorFilter(if (selected) selectedIconColor else blue)
                background = rounded(if (selected) selectedBackground else surface, dp(controlSize / 2).toFloat(), line, 1)
            }
            setPadding(dp(iconPadding), dp(iconPadding), dp(iconPadding), dp(iconPadding))
            display(initialSelected)
            setOnClickListener {
                display(action())
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
        sub(parent, label, TvoiceUi.SECONDARY_SP.toInt(), dark, if (parent.childCount == 0) 0 else 14).typeface = TvoiceUi.medium()
        val field = EditText(this).apply {
            this.hint = hint
            TvoiceUi.style(this, TvoiceUi.BODY_SP, dark)
            setHintTextColor(muted)
            inputType = if (password) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_CLASS_PHONE
            setPadding(dp(16), 0, dp(16), 0)
            background = rounded(surface, dp(12).toFloat(), line, 1)
        }
        parent.addView(field, LinearLayout.LayoutParams(-1, dp(TvoiceUi.FIELD_DP)).apply { topMargin = dp(7) })
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
            this.text = text
            TvoiceUi.style(this, TvoiceUi.BUTTON_SP, Color.WHITE, TvoiceUi.semiBold())
            background = rounded(color, dp(12).toFloat())
            stateListAnimator = null
            setOnClickListener(action)
        }
        parent.addView(button, LinearLayout.LayoutParams(-1, dp(TvoiceUi.FIELD_DP)).apply { topMargin = dp(top) })
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

    private fun pageTitle(parent: LinearLayout, title: String): TextView = heading(
        parent,
        title,
        TvoiceUi.PAGE_TITLE_SP.toInt(),
        dark,
        2
    ).apply { typeface = TvoiceUi.bold() }

    private fun sectionLabel(parent: LinearLayout, title: String): TextView = sub(
        parent,
        title,
        TvoiceUi.SECONDARY_SP.toInt(),
        muted,
        14
    ).apply {
        typeface = TvoiceUi.medium()
        letterSpacing = 0.02f
    }

    private fun searchField(parent: LinearLayout, hint: String, initial: String = "", onChanged: (String) -> Unit): EditText {
        val icon = ContextCompat.getDrawable(this, R.drawable.ic_search)?.mutate()?.apply { setTint(muted) }
        val field = EditText(this).apply {
            this.hint = hint
            setText(initial)
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT
            TvoiceUi.style(this, TvoiceUi.BODY_SP, dark)
            setHintTextColor(muted)
            setPadding(dp(12), 0, dp(12), 0)
            setCompoundDrawablesWithIntrinsicBounds(icon, null, null, null)
            compoundDrawablePadding = dp(8)
            background = rounded(TvoiceUi.color(this@MainActivity, R.color.tvoice_search), dp(10).toFloat())
            doAfterTextChanged { onChanged(it?.toString().orEmpty()) }
        }
        parent.addView(field, LinearLayout.LayoutParams(-1, dp(TvoiceUi.SEARCH_DP)).apply { topMargin = dp(10) })
        return field
    }

    private fun heading(parent: LinearLayout, text: String, size: Int, color: Int, top: Int): TextView {
        val v = TextView(this).apply {
            this.text = text
            TvoiceUi.style(this, size.toFloat(), color, TvoiceUi.semiBold())
            gravity = if (parent.gravity == Gravity.CENTER_HORIZONTAL || parent.gravity == Gravity.CENTER) Gravity.CENTER else Gravity.START
        }
        parent.addView(v, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }); return v
    }

    private fun sub(parent: LinearLayout, text: String, size: Int, color: Int, top: Int): TextView {
        val v = TextView(this).apply {
            this.text = text
            TvoiceUi.style(this, size.toFloat(), color)
            gravity = if (parent.gravity == Gravity.CENTER_HORIZONTAL || parent.gravity == Gravity.CENTER) Gravity.CENTER else Gravity.START
        }
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
    private fun formatDuration(seconds: Long): String = CallDurationFormatter.format(seconds)
    private fun formatTime(timestamp: Long) = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(timestamp))
    private fun now() = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date())
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun statusBarHeight(): Int = dp(24)
    private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_LONG).show()
    override fun onDestroy() {
        stopCallTimer()
        videoControlsHideTask?.let(uiHandler::removeCallbacks)
        if (sip.isVideoCall) sip.setVideoSurfaces(null, null)
        TvoiceRuntime.removeObserver(this)
        ChatClient.removeObserver(this)
        super.onDestroy()
    }

    companion object {
        const val EXTRA_OPEN_CHAT = "tj.tvoice.app.extra.OPEN_CHAT"
        private const val REQUEST_CHAT_ATTACHMENT = 21
        private const val STATE_HOME_PAGE = "home_page"
        private const val STATE_CHAT_PEER = "chat_peer"
        private const val STATE_CALL_MINIMIZED = "call_minimized"
        private const val PREF_FAVORITE_CALLS = "favorite_call_numbers"
        private const val EXTRA_UI_PREVIEW = "ui_preview"
        private const val EXTRA_UI_PREVIEW_DARK = "ui_preview_dark"
        private const val EXTRA_UI_PREVIEW_LANGUAGE = "ui_preview_language"
    }
}
