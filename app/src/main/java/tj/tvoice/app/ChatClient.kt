package tj.tvoice.app

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.HttpUrl.Companion.toHttpUrl
import okio.BufferedSink
import okio.source
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * HTTPS/WSS client for the dedicated Tvoice Chat service.
 *
 * The SIP password is used only to obtain a short-lived chat token. The token
 * and plaintext password remain in process memory; the saved account password
 * continues to be protected by [CredentialStore].
 */
object ChatClient {
    interface Observer {
        fun onChatState(connected: Boolean, message: String) = Unit
        fun onChatSync(peer: String?) = Unit
        fun onChatMessage(message: ChatMessage) = Unit
    }

    private const val BASE_URL = "https://chat.185-177-2-115.sslip.io"
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()
    private val observers = CopyOnWriteArraySet<Observer>()
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val conversationByPeer = ConcurrentHashMap<String, String>()
    private val peerByConversation = ConcurrentHashMap<String, String>()
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(25, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .pingInterval(25, TimeUnit.SECONDS)
        .build()

    private var initialized = false
    private var appContext: Context? = null
    private var generation = 0
    private var webSocket: WebSocket? = null
    private var reconnectRunnable: Runnable? = null

    @Volatile private var accessToken = ""
    @Volatile private var activeUsername = ""
    @Volatile private var activePassword = ""
    @Volatile var isConnected = false
        private set
    @Volatile var stateMessage = ""
        private set

    @Synchronized
    fun initialize(context: Context) {
        if (initialized) return
        appContext = context.applicationContext
        initialized = true
    }

    fun addObserver(observer: Observer) {
        observers += observer
    }

    fun removeObserver(observer: Observer) {
        observers -= observer
    }

    @Synchronized
    fun login(username: String, password: String) {
        val normalized = username.trim()
        if (normalized.isBlank() || password.length < 5) {
            notifyState(false, "Чат: неверный логин или пароль")
            return
        }
        if (
            activeUsername == normalized &&
            activePassword == password &&
            accessToken.isNotBlank()
        ) {
            if (!isConnected && webSocket == null) {
                connectWebSocket(generation, accessToken)
            }
            return
        }

        generation += 1
        val requestGeneration = generation
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = null
        webSocket?.close(1000, "Account changed")
        webSocket = null
        accessToken = ""
        activeUsername = normalized
        activePassword = password
        isConnected = false
        conversationByPeer.clear()
        peerByConversation.clear()
        notifyState(false, "Подключение чата…")

        worker.execute {
            runCatching {
                val body = JSONObject()
                    .put("sipNumber", normalized)
                    .put("password", password)
                requestJson("/v1/auth/login", "POST", body, authenticated = false)
                    .getString("accessToken")
            }.onSuccess { token ->
                if (!isCurrent(requestGeneration)) return@onSuccess
                accessToken = token
                connectWebSocket(requestGeneration, token)
                syncAllInternal(requestGeneration)
            }.onFailure { error ->
                if (!isCurrent(requestGeneration)) return@onFailure
                notifyState(false, friendlyError(error))
                scheduleReconnect(requestGeneration)
            }
        }
    }

    @Synchronized
    fun logout() {
        generation += 1
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = null
        webSocket?.close(1000, "Logout")
        webSocket = null
        accessToken = ""
        activeUsername = ""
        activePassword = ""
        isConnected = false
        conversationByPeer.clear()
        peerByConversation.clear()
        notifyState(false, "")
    }

    fun reconnect() {
        val username = activeUsername
        val password = activePassword
        if (username.isNotBlank() && password.isNotBlank()) login(username, password)
    }

    fun syncAll() {
        val requestGeneration = generation
        if (accessToken.isBlank()) return
        worker.execute { syncAllInternal(requestGeneration) }
    }

    fun syncConversation(peerNumber: String) {
        val peer = peerNumber.trim()
        val requestGeneration = generation
        if (peer.isBlank() || accessToken.isBlank()) return
        worker.execute {
            runCatching {
                val conversationId = ensureConversation(peer)
                fetchMessages(conversationId, peer)
            }.onSuccess {
                if (isCurrent(requestGeneration)) notifySync(peer)
            }.onFailure { error ->
                if (isCurrent(requestGeneration)) notifyState(isConnected, friendlyError(error))
            }
        }
    }

    fun sendMessage(peerNumber: String, textValue: String) {
        val peer = peerNumber.trim()
        val text = textValue.trim()
        require(peer.isNotBlank()) { "Введите номер абонента" }
        require(text.isNotBlank()) { "Введите сообщение" }
        check(accessToken.isNotBlank()) { "Чат ещё не подключён" }

        val username = activeUsername
        val requestGeneration = generation
        ChatStore.addOutgoing(username, peer, text)
        notifySync(peer)

        worker.execute {
            runCatching {
                val conversationId = ensureConversation(peer)
                val response = requestJson(
                    "/v1/conversations/$conversationId/messages",
                    "POST",
                    JSONObject().put("body", text)
                )
                val message = response.getJSONObject("message")
                val serverId = message.getString("id").toLong()
                val timestamp = parseTimestamp(message.getString("createdAt"))
                ChatStore.confirmOutgoing(username, peer, text, serverId, timestamp)
            }.onSuccess {
                if (isCurrent(requestGeneration)) notifySync(peer)
            }.onFailure { error ->
                ChatStore.markLatest(username, peer, text, delivered = false)
                if (isCurrent(requestGeneration)) {
                    notifySync(peer)
                    notifyState(isConnected, friendlyError(error))
                }
            }
        }
    }

    fun sendAttachment(peerNumber: String, uri: Uri) {
        val peer = peerNumber.trim()
        require(peer.isNotBlank()) { "Введите номер абонента" }
        check(accessToken.isNotBlank()) { "Чат ещё не подключён" }
        val context = checkNotNull(appContext) { "Tvoice Chat не инициализирован" }
        val metadata = attachmentMetadata(context.contentResolver, uri)
        require(metadata.size <= MAX_ATTACHMENT_SIZE || metadata.size < 0) {
            "Файл больше 20 МБ"
        }

        val username = activeUsername
        val requestGeneration = generation
        ChatStore.addOutgoingAttachment(
            username,
            peer,
            metadata.name,
            metadata.mimeType,
            metadata.size.coerceAtLeast(0)
        )
        notifySync(peer)

        worker.execute {
            runCatching {
                val conversationId = ensureConversation(peer)
                val response = uploadAttachment(conversationId, uri, metadata)
                val message = response.getJSONObject("message")
                val attachment = message.getJSONObject("attachment")
                ChatStore.confirmOutgoing(
                    owner = username,
                    peer = peer,
                    text = message.getString("body"),
                    serverId = message.getString("id").toLong(),
                    timestamp = parseTimestamp(message.getString("createdAt")),
                    attachmentId = attachment.getString("id"),
                    attachmentName = attachment.getString("name"),
                    attachmentMime = attachment.getString("mimeType"),
                    attachmentSize = attachment.getLong("size")
                )
            }.onSuccess {
                if (isCurrent(requestGeneration)) notifySync(peer)
            }.onFailure { error ->
                ChatStore.markLatest(username, peer, metadata.name, delivered = false)
                if (isCurrent(requestGeneration)) {
                    notifySync(peer)
                    notifyState(isConnected, friendlyError(error))
                }
            }
        }
    }

    fun downloadAttachment(message: ChatMessage, callback: (Result<File>) -> Unit) {
        val attachmentId = message.attachmentId
        if (attachmentId.isNullOrBlank()) {
            callback(Result.failure(IllegalStateException("Файл ещё загружается")))
            return
        }
        val context = checkNotNull(appContext) { "Tvoice Chat не инициализирован" }
        val token = accessToken
        if (token.isBlank()) {
            callback(Result.failure(IllegalStateException("Чат ещё не подключён")))
            return
        }
        worker.execute {
            val result = runCatching {
                val directory = File(context.cacheDir, "chat_attachments").apply { mkdirs() }
                val safeName = message.attachmentName.orEmpty()
                    .replace(Regex("[^\\p{L}\\p{N}._-]"), "_")
                    .take(100)
                    .ifBlank { "file" }
                val target = File(directory, "${attachmentId}_$safeName")
                if (target.isFile && target.length() > 0) return@runCatching target
                val request = Request.Builder()
                    .url("$BASE_URL/v1/attachments/$attachmentId")
                    .header("Authorization", "Bearer $token")
                    .build()
                client.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) error("HTTP ${response.code}")
                    val body = checkNotNull(response.body)
                    FileOutputStream(target).use { output ->
                        body.byteStream().use { input -> input.copyTo(output) }
                    }
                }
                target
            }
            mainHandler.post { callback(result) }
        }
    }

    private fun syncAllInternal(requestGeneration: Int) {
        runCatching {
            val response = requestJson("/v1/conversations", "GET")
            val conversations = response.getJSONArray("conversations")
            for (index in 0 until conversations.length()) {
                if (!isCurrent(requestGeneration)) return
                val conversation = conversations.getJSONObject(index)
                val id = conversation.getString("id")
                val peer = conversation.getJSONObject("peer").getString("sipNumber")
                conversationByPeer[peer] = id
                peerByConversation[id] = peer
                fetchMessages(id, peer)
            }
        }.onSuccess {
            if (isCurrent(requestGeneration)) notifySync(null)
        }.onFailure { error ->
            if (isCurrent(requestGeneration)) notifyState(isConnected, friendlyError(error))
        }
    }

    private fun ensureConversation(peer: String): String {
        conversationByPeer[peer]?.let { return it }
        val response = requestJson(
            "/v1/conversations/direct",
            "POST",
            JSONObject().put("peerSipNumber", peer)
        )
        val conversation = response.getJSONObject("conversation")
        val id = conversation.getString("id")
        val resolvedPeer = conversation.getJSONObject("peer").getString("sipNumber")
        conversationByPeer[resolvedPeer] = id
        peerByConversation[id] = resolvedPeer
        return id
    }

    private fun fetchMessages(conversationId: String, peer: String) {
        val response = requestJson(
            "/v1/conversations/$conversationId/messages?limit=100",
            "GET"
        )
        val username = activeUsername
        val messages = response.getJSONArray("messages")
        for (index in 0 until messages.length()) {
            val message = messages.getJSONObject(index)
            val sender = message.getJSONObject("sender").getString("sipNumber")
            ChatStore.upsertServer(
                owner = username,
                peer = peer,
                serverId = message.getString("id").toLong(),
                text = message.getString("body"),
                incoming = sender != username,
                timestamp = parseTimestamp(message.getString("createdAt")),
                attachmentId = message.optJSONObject("attachment")?.optString("id"),
                attachmentName = message.optJSONObject("attachment")?.optString("name"),
                attachmentMime = message.optJSONObject("attachment")?.optString("mimeType"),
                attachmentSize = message.optJSONObject("attachment")?.optLong("size") ?: 0
            )
        }
    }

    private fun connectWebSocket(requestGeneration: Int, token: String) {
        if (!isCurrent(requestGeneration)) return
        val httpsUrl = "$BASE_URL/v1/ws".toHttpUrl().newBuilder()
            .addQueryParameter("token", token)
            .build()
            .toString()
        val socketUrl = httpsUrl.replaceFirst("https://", "wss://")
        val request = Request.Builder().url(socketUrl).build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (!isCurrent(requestGeneration)) {
                    webSocket.close(1000, "Stale session")
                    return
                }
                isConnected = true
                stateMessage = ""
                notifyState(true, "")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (!isCurrent(requestGeneration)) return
                handleSocketMessage(text)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!isCurrent(requestGeneration)) return
                this@ChatClient.webSocket = null
                isConnected = false
                notifyState(false, "Чат отключён, повторное подключение…")
                scheduleReconnect(requestGeneration)
            }

            override fun onFailure(webSocket: WebSocket, error: Throwable, response: Response?) {
                if (!isCurrent(requestGeneration)) return
                this@ChatClient.webSocket = null
                isConnected = false
                notifyState(false, friendlyError(error))
                scheduleReconnect(requestGeneration)
            }
        })
    }

    private fun handleSocketMessage(raw: String) {
        val event = runCatching { JSONObject(raw) }.getOrNull() ?: return
        if (event.optString("type") != "message.new") return
        val payload = event.optJSONObject("message") ?: return
        val conversationId = payload.optString("conversationId")
        val sender = payload.optJSONObject("sender")?.optString("sipNumber").orEmpty()
        val username = activeUsername
        val peer = if (sender != username) sender else peerByConversation[conversationId].orEmpty()
        if (peer.isBlank()) {
            syncAll()
            return
        }
        conversationByPeer[peer] = conversationId
        peerByConversation[conversationId] = peer
        val message = ChatStore.upsertServer(
            owner = username,
            peer = peer,
            serverId = payload.getString("id").toLong(),
            text = payload.getString("body"),
            incoming = sender != username,
            timestamp = parseTimestamp(payload.getString("createdAt")),
            attachmentId = payload.optJSONObject("attachment")?.optString("id"),
            attachmentName = payload.optJSONObject("attachment")?.optString("name"),
            attachmentMime = payload.optJSONObject("attachment")?.optString("mimeType"),
            attachmentSize = payload.optJSONObject("attachment")?.optLong("size") ?: 0
        )
        notifySync(peer)
        if (message.incoming) observers.forEach { observer ->
            runCatching { observer.onChatMessage(message) }
        }
    }

    private fun requestJson(
        path: String,
        method: String,
        body: JSONObject? = null,
        authenticated: Boolean = true
    ): JSONObject {
        val builder = Request.Builder()
            .url("$BASE_URL$path")
            .header("Accept", "application/json")
        if (authenticated) {
            val token = accessToken
            check(token.isNotBlank()) { "Чат ещё не подключён" }
            builder.header("Authorization", "Bearer $token")
        }
        when (method) {
            "GET" -> builder.get()
            "POST" -> builder.post((body ?: JSONObject()).toString().toRequestBody(jsonMediaType))
            else -> error("Unsupported method")
        }
        return client.newCall(builder.build()).execute().use { response ->
            val responseText = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                val code = runCatching { JSONObject(responseText).optString("error") }.getOrNull()
                throw IllegalStateException(code?.takeIf { it.isNotBlank() } ?: "HTTP ${response.code}")
            }
            if (responseText.isBlank()) JSONObject() else JSONObject(responseText)
        }
    }

    private fun uploadAttachment(
        conversationId: String,
        uri: Uri,
        metadata: AttachmentMetadata
    ): JSONObject {
        val context = checkNotNull(appContext)
        val resolver = context.contentResolver
        val streamBody = object : RequestBody() {
            override fun contentType() = metadata.mimeType.toMediaTypeOrNull()
            override fun contentLength(): Long = metadata.size
            override fun writeTo(sink: BufferedSink) {
                val input = checkNotNull(resolver.openInputStream(uri)) { "Не удалось открыть файл" }
                input.use { sink.writeAll(it.source()) }
            }
        }
        val multipartBody = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("file", metadata.name, streamBody)
            .build()
        val request = Request.Builder()
            .url("$BASE_URL/v1/conversations/$conversationId/attachments")
            .header("Authorization", "Bearer $accessToken")
            .post(multipartBody)
            .build()
        return client.newCall(request).execute().use { response ->
            val responseText = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                val code = runCatching { JSONObject(responseText).optString("error") }.getOrNull()
                error(code?.takeIf(String::isNotBlank) ?: "HTTP ${response.code}")
            }
            JSONObject(responseText)
        }
    }

    private fun attachmentMetadata(resolver: ContentResolver, uri: Uri): AttachmentMetadata {
        var name = "file"
        var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIndex >= 0) name = cursor.getString(nameIndex).orEmpty().ifBlank { "file" }
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                }
            }
        return AttachmentMetadata(
            name = name.take(255),
            mimeType = resolver.getType(uri) ?: "application/octet-stream",
            size = size
        )
    }

    @Synchronized
    private fun scheduleReconnect(requestGeneration: Int) {
        if (!isCurrent(requestGeneration) || activeUsername.isBlank()) return
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = Runnable {
            if (isCurrent(requestGeneration) && activeUsername.isNotBlank()) {
                login(activeUsername, activePassword)
            }
        }.also { mainHandler.postDelayed(it, 5_000) }
    }

    private fun notifyState(connected: Boolean, message: String) {
        isConnected = connected
        stateMessage = message
        observers.forEach { observer ->
            runCatching { observer.onChatState(connected, message) }
        }
    }

    private fun notifySync(peer: String?) {
        observers.forEach { observer ->
            runCatching { observer.onChatSync(peer) }
        }
    }

    @Synchronized
    private fun isCurrent(requestGeneration: Int): Boolean =
        requestGeneration == generation

    private fun parseTimestamp(value: String): Long =
        runCatching { Instant.parse(value).toEpochMilli() }.getOrDefault(System.currentTimeMillis())

    private fun friendlyError(error: Throwable): String {
        val message = error.message.orEmpty()
        return when {
            message.contains("invalid_credentials") -> "Чат: неверный логин или пароль"
            message.contains("contact_not_found") -> "Абонент не подключён к чату"
            message.contains("cannot_message_yourself") -> "Нельзя написать самому себе"
            message.contains("file_too_large") -> "Файл больше 20 МБ"
            message.contains("file_required") -> "Не удалось прочитать файл"
            message.contains("timeout", ignoreCase = true) -> "Чат: сервер не отвечает"
            message.contains("Unable to resolve host", ignoreCase = true) -> "Чат: нет подключения к интернету"
            else -> "Чат: ${message.ifBlank { "ошибка подключения" }}"
        }
    }

    private data class AttachmentMetadata(
        val name: String,
        val mimeType: String,
        val size: Long
    )

    private const val MAX_ATTACHMENT_SIZE = 20L * 1024 * 1024
}
