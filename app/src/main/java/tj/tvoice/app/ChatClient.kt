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
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
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
 * continues to be protected by [AccountStore].
 */
object ChatClient {
    data class Contact(val sipNumber: String, val displayName: String)
    data class VideoCallInvite(
        val callId: String,
        val peerNumber: String,
        val peerName: String,
        val expiresAt: String
    )
    data class VideoCallCredentials(
        val callId: String,
        val room: String,
        val url: String,
        val token: String,
        val peerNumber: String,
        val peerName: String
    )

    interface Observer {
        fun onChatState(connected: Boolean, message: String) = Unit
        fun onChatSync(peer: String?) = Unit
        fun onChatMessage(message: ChatMessage) = Unit
        fun onIncomingVideoCall(invite: VideoCallInvite) = Unit
        fun onVideoCallAnswered(callId: String) = Unit
        fun onVideoCallEnded(callId: String, reason: String) = Unit
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
    @Volatile private var generation = 0
    private var webSocket: WebSocket? = null
    private var reconnectRunnable: Runnable? = null
    @Volatile private var reconnectDelaySeconds = 5L

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
        val normalized = SipIdentity.normalize(username)
        // FreePBX does not impose a client-side minimum password length. Rejecting
        // short but valid SIP secrets here made SIP login succeed while chat login
        // was never even sent to the server.
        if (normalized.isBlank() || password.isBlank()) {
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
        ChatStore.failSending()
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = null
        reconnectDelaySeconds = 5L
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
                if (!error.message.orEmpty().contains("invalid_credentials")) {
                    scheduleReconnect(requestGeneration)
                }
            }
        }
    }

    @Synchronized
    fun logout() {
        generation += 1
        ChatStore.failSending()
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = null
        reconnectDelaySeconds = 5L
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

    fun loadContacts(callback: (Result<List<Contact>>) -> Unit) {
        val requestGeneration = generation
        if (accessToken.isBlank()) {
            callback(Result.failure(IllegalStateException("Чат ещё не подключён")))
            return
        }
        worker.execute {
            val result = runCatching {
                val response = requestJson("/v1/contacts", "GET")
                val array = response.optJSONArray("contacts")
                    ?: response.optJSONArray("items")
                    ?: JSONArray()
                buildList<Contact> {
                    for (index in 0 until array.length()) {
                        val item = array.optJSONObject(index) ?: continue
                        val entity = item.optJSONObject("contact")
                            ?: item.optJSONObject("subscriber")
                            ?: item.optJSONObject("user")
                            ?: item
                        val number = runCatching { SipIdentity.requireValid(
                            entity.optString("sipNumber")
                                .ifBlank { item.optString("sipNumber") }
                                .ifBlank { item.optString("contactSipNumber") }
                        ) }.getOrNull() ?: continue
                        if (number == activeUsername || any { it.sipNumber == number }) continue
                        val name = item.optString("displayName")
                            .ifBlank { item.optString("name") }
                            .ifBlank { item.optString("alias") }
                            .ifBlank { entity.optString("displayName") }
                            .ifBlank { entity.optString("name") }
                            .ifBlank { number }
                        add(Contact(number, name))
                    }
                }
            }
            mainHandler.post {
                if (isCurrent(requestGeneration)) callback(result)
            }
        }
    }

    fun syncConversation(peerNumber: String) {
        val peer = SipIdentity.normalize(peerNumber)
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
        val peer = SipIdentity.requireValid(peerNumber)
        val text = textValue.trim()
        require(peer.isNotBlank()) { "Введите номер абонента" }
        require(text.isNotBlank()) { "Введите сообщение" }
        check(accessToken.isNotBlank()) { "Чат ещё не подключён" }

        val username = activeUsername
        val requestGeneration = generation
        val pending = ChatStore.addOutgoing(username, peer, text)
        notifySync(peer)

        deliverText(username, peer, text, pending.id, requestGeneration)
    }

    fun startVideoCall(peerNumber: String, callback: (Result<VideoCallCredentials>) -> Unit) {
        val peer = SipIdentity.requireValid(peerNumber)
        videoCallRequest(
            "/v1/video/calls",
            JSONObject().put("peerSipNumber", peer),
            callback
        )
    }

    fun answerVideoCall(callId: String, callback: (Result<VideoCallCredentials>) -> Unit) {
        videoCallRequest("/v1/video/calls/$callId/answer", JSONObject(), callback)
    }

    fun rejectVideoCall(callId: String) = finishVideoCall(callId, "reject")

    fun endVideoCall(callId: String) = finishVideoCall(callId, "end")

    private fun videoCallRequest(
        path: String,
        body: JSONObject,
        callback: (Result<VideoCallCredentials>) -> Unit
    ) {
        val requestGeneration = generation
        if (accessToken.isBlank()) {
            callback(Result.failure(IllegalStateException("Чат ещё не подключён")))
            return
        }
        worker.execute {
            val result = runCatching {
                val response = requestJson(path, "POST", body)
                if (response.has("delivered") && !response.optBoolean("delivered")) {
                    throw IllegalStateException("Абонент сейчас не подключён к видеозвонкам")
                }
                val peer = response.optJSONObject("peer") ?: JSONObject()
                VideoCallCredentials(
                    callId = response.getString("callId"),
                    room = response.getString("room"),
                    url = response.getString("url"),
                    token = response.getString("token"),
                    peerNumber = SipIdentity.normalize(peer.optString("sipNumber")),
                    peerName = peer.optString("displayName").ifBlank {
                        SipIdentity.normalize(peer.optString("sipNumber"))
                    }
                )
            }
            mainHandler.post {
                if (isCurrent(requestGeneration)) callback(result)
            }
        }
    }

    private fun finishVideoCall(callId: String, action: String) {
        if (callId.isBlank() || accessToken.isBlank()) return
        val requestGeneration = generation
        worker.execute {
            runCatching { requestJson("/v1/video/calls/$callId/$action", "POST") }
                .onFailure { error ->
                    if (isCurrent(requestGeneration) &&
                        !error.message.orEmpty().contains("call_not_found")) {
                        notifyState(isConnected, friendlyError(error))
                    }
                }
        }
    }

    fun retryMessage(message: ChatMessage) {
        require(!message.incoming && message.status == "failed" && message.attachmentName == null) {
            "Это сообщение нельзя отправить повторно"
        }
        check(accessToken.isNotBlank()) { "Чат ещё не подключён" }
        check(message.owner == activeUsername) { "Сначала переключитесь на аккаунт ${message.owner}" }
        val peer = SipIdentity.requireValid(message.peer)
        ChatStore.markSending(message.id)
        notifySync(peer)
        deliverText(activeUsername, peer, message.text, message.id, generation)
    }

    private fun deliverText(username: String, peer: String, text: String, localId: String, requestGeneration: Int) {
        worker.execute {
            if (!isCurrent(requestGeneration) || username != activeUsername) return@execute
            runCatching {
                val conversationId = ensureConversation(peer)
                val response = requestJson(
                    "/v1/conversations/$conversationId/messages",
                    "POST",
                    JSONObject().put("body", text)
                )
                val message = response.getJSONObject("message")
                val serverId = message.getString("id")
                val timestamp = parseTimestamp(message.getString("createdAt"))
                ChatStore.confirmOutgoing(
                    username,
                    peer,
                    text,
                    localId,
                    serverId,
                    timestamp,
                    status = message.optString("status", "sent")
                )
            }.onSuccess {
                if (isCurrent(requestGeneration)) notifySync(peer)
            }.onFailure { error ->
                val friendly = friendlyError(error)
                ChatStore.markOutgoing(localId, delivered = false, error = friendly)
                if (isCurrent(requestGeneration)) {
                    notifySync(peer)
                    notifyState(isConnected, friendly)
                }
            }
        }
    }

    fun sendAttachment(peerNumber: String, uri: Uri) {
        val peer = SipIdentity.requireValid(peerNumber)
        require(peer.isNotBlank()) { "Введите номер абонента" }
        check(accessToken.isNotBlank()) { "Чат ещё не подключён" }
        val context = checkNotNull(appContext) { "Tvoice Chat не инициализирован" }
        val metadata = attachmentMetadata(context.contentResolver, uri)
        require(metadata.size <= MAX_ATTACHMENT_SIZE || metadata.size < 0) {
            "Файл больше 20 МБ"
        }

        val username = activeUsername
        val requestGeneration = generation
        val pending = ChatStore.addOutgoingAttachment(
            username,
            peer,
            metadata.name,
            metadata.mimeType,
            metadata.size.coerceAtLeast(0)
        )
        notifySync(peer)

        worker.execute {
            if (!isCurrent(requestGeneration) || username != activeUsername) return@execute
            runCatching {
                val conversationId = ensureConversation(peer)
                val response = uploadAttachment(conversationId, uri, metadata)
                val message = response.getJSONObject("message")
                val attachment = message.getJSONObject("attachment")
                ChatStore.confirmOutgoing(
                    owner = username,
                    peer = peer,
                    text = message.getString("body"),
                    localId = pending.id,
                    serverId = message.getString("id"),
                    timestamp = parseTimestamp(message.getString("createdAt")),
                    attachmentId = attachment.getString("id"),
                    attachmentName = attachment.getString("name"),
                    attachmentMime = attachment.getString("mimeType"),
                    attachmentSize = attachment.getLong("size"),
                    status = message.optString("status", "sent")
                )
            }.onSuccess {
                if (isCurrent(requestGeneration)) notifySync(peer)
            }.onFailure { error ->
                ChatStore.markOutgoing(pending.id, delivered = false, error = friendlyError(error))
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
                if (target.isFile && target.length() in 1..MAX_ATTACHMENT_SIZE) return@runCatching target
                if (target.exists()) target.delete()
                val partial = File(directory, ".${attachmentId}.part")
                partial.delete()
                val request = Request.Builder()
                    .url("$BASE_URL/v1/attachments/$attachmentId")
                    .header("Authorization", "Bearer $token")
                    .build()
                client.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) error("HTTP ${response.code}")
                    val body = checkNotNull(response.body)
                    val declaredSize = body.contentLength()
                    require(declaredSize < 0 || declaredSize <= MAX_ATTACHMENT_SIZE) { "Файл больше 20 МБ" }
                    try {
                        FileOutputStream(partial).use { output ->
                            body.byteStream().use { input ->
                                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                var total = 0L
                                while (true) {
                                    val read = input.read(buffer)
                                    if (read < 0) break
                                    total += read
                                    require(total <= MAX_ATTACHMENT_SIZE) { "Файл больше 20 МБ" }
                                    output.write(buffer, 0, read)
                                }
                            }
                        }
                        check(partial.renameTo(target)) { "Не удалось сохранить файл" }
                    } finally {
                        if (partial.exists()) partial.delete()
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
                val peer = SipIdentity.normalize(conversation.getJSONObject("peer").getString("sipNumber"))
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
        val resolvedPeer = SipIdentity.normalize(conversation.getJSONObject("peer").getString("sipNumber"))
        conversationByPeer[peer] = id
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
            val sender = SipIdentity.normalize(message.getJSONObject("sender").getString("sipNumber"))
            ChatStore.upsertServer(
                owner = username,
                peer = peer,
                serverId = message.getString("id"),
                text = message.getString("body"),
                incoming = sender != username,
                timestamp = parseTimestamp(message.getString("createdAt")),
                attachmentId = message.optJSONObject("attachment")?.optString("id"),
                attachmentName = message.optJSONObject("attachment")?.optString("name"),
                attachmentMime = message.optJSONObject("attachment")?.optString("mimeType"),
                attachmentSize = message.optJSONObject("attachment")?.optLong("size") ?: 0,
                serverStatus = message.optString("status", "sent")
            )
        }
    }

    fun markConversationRead(peerNumber: String) {
        val peer = SipIdentity.normalize(peerNumber)
        val requestGeneration = generation
        if (peer.isBlank() || accessToken.isBlank()) return
        worker.execute {
            runCatching {
                val conversationId = ensureConversation(peer)
                requestJson("/v1/conversations/$conversationId/read", "POST")
            }.onSuccess {
                if (isCurrent(requestGeneration)) notifySync(peer)
            }.onFailure { error ->
                if (isCurrent(requestGeneration)) notifyState(isConnected, friendlyError(error))
            }
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
                reconnectDelaySeconds = 5L
                stateMessage = ""
                notifyState(true, "")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (!isCurrent(requestGeneration)) return
                if (text.toByteArray().size > MAX_JSON_RESPONSE_SIZE) return
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
        val type = event.optString("type")
        if (type == "video.call.incoming") {
            val from = event.optJSONObject("from") ?: return
            val invite = VideoCallInvite(
                callId = event.optString("callId"),
                peerNumber = SipIdentity.normalize(from.optString("sipNumber")),
                peerName = from.optString("displayName").ifBlank {
                    SipIdentity.normalize(from.optString("sipNumber"))
                },
                expiresAt = event.optString("expiresAt")
            )
            if (invite.callId.isBlank() || invite.peerNumber.isBlank()) return
            observers.forEach { observer ->
                runCatching { observer.onIncomingVideoCall(invite) }
            }
            return
        }
        if (type == "video.call.answered") {
            val callId = event.optString("callId")
            observers.forEach { observer -> runCatching { observer.onVideoCallAnswered(callId) } }
            return
        }
        if (type == "video.call.rejected" || type == "video.call.ended") {
            val callId = event.optString("callId")
            val reason = if (type.endsWith("rejected")) "rejected" else event.optString("reason", "ended")
            observers.forEach { observer ->
                runCatching { observer.onVideoCallEnded(callId, reason) }
            }
            return
        }
        if (type == "message.delivered" || type == "message.read") {
            val conversationId = event.optString("conversationId")
            val peer = peerByConversation[conversationId].orEmpty()
            val through = event.optString("throughCreatedAt")
                .takeIf(String::isNotBlank)
                ?.let(::parseTimestamp)
                ?: return
            if (peer.isBlank()) {
                syncAll()
                return
            }
            ChatStore.markOutgoingReceipt(
                activeUsername,
                peer,
                through,
                if (type == "message.read") "read" else "delivered"
            )
            notifySync(peer)
            return
        }
        if (type != "message.new") return
        val payload = event.optJSONObject("message") ?: return
        val conversationId = payload.optString("conversationId")
        val sender = SipIdentity.normalize(payload.optJSONObject("sender")?.optString("sipNumber").orEmpty())
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
            serverId = payload.getString("id"),
            text = payload.getString("body"),
            incoming = sender != username,
            timestamp = parseTimestamp(payload.getString("createdAt")),
            attachmentId = payload.optJSONObject("attachment")?.optString("id"),
            attachmentName = payload.optJSONObject("attachment")?.optString("name"),
            attachmentMime = payload.optJSONObject("attachment")?.optString("mimeType"),
            attachmentSize = payload.optJSONObject("attachment")?.optLong("size") ?: 0,
            serverStatus = payload.optString("status", "sent")
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
        val requestGeneration = generation
        val requestUsername = activeUsername
        val requestPassword = activePassword
        val token = if (authenticated) {
            accessToken.takeIf(String::isNotBlank) ?: error("Чат ещё не подключён")
        } else null
        return try {
            executeJsonRequest(path, method, body, token)
        } catch (error: ChatApiException) {
            if (
                !authenticated ||
                error.statusCode != 401 ||
                requestUsername.isBlank() ||
                requestPassword.isBlank() ||
                !isCurrent(requestGeneration) ||
                activeUsername != requestUsername
            ) {
                throw error
            }
            val refreshedToken = executeJsonRequest(
                "/v1/auth/login",
                "POST",
                JSONObject().put("sipNumber", requestUsername).put("password", requestPassword),
                null
            ).getString("accessToken")
            check(isCurrent(requestGeneration) && activeUsername == requestUsername) {
                "Аккаунт чата изменился во время запроса"
            }
            accessToken = refreshedToken
            executeJsonRequest(path, method, body, refreshedToken)
        }
    }

    private fun executeJsonRequest(
        path: String,
        method: String,
        body: JSONObject?,
        token: String?
    ): JSONObject {
        val builder = Request.Builder()
            .url("$BASE_URL$path")
            .header("Accept", "application/json")
        if (!token.isNullOrBlank()) builder.header("Authorization", "Bearer $token")
        when (method) {
            "GET" -> builder.get()
            "POST" -> builder.post((body ?: JSONObject()).toString().toRequestBody(jsonMediaType))
            else -> error("Unsupported method")
        }
        return client.newCall(builder.build()).execute().use { response ->
            val responseText = readResponseText(response)
            if (!response.isSuccessful) {
                val code = runCatching { JSONObject(responseText).optString("error") }.getOrNull()
                throw ChatApiException(response.code, code?.takeIf { it.isNotBlank() } ?: "HTTP ${response.code}")
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
                input.use {
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val read = it.read(buffer)
                        if (read < 0) break
                        total += read
                        require(total <= MAX_ATTACHMENT_SIZE) { "Файл больше 20 МБ" }
                        sink.write(buffer, 0, read)
                    }
                }
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
            val responseText = readResponseText(response)
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
            name = name.replace(Regex("[\\r\\n\\u0000]"), "_").take(255),
            mimeType = resolver.getType(uri) ?: "application/octet-stream",
            size = size
        )
    }

    private fun readResponseText(response: Response): String {
        val body = response.body ?: return ""
        val declared = body.contentLength()
        require(declared < 0 || declared <= MAX_JSON_RESPONSE_SIZE) { "Ответ сервера слишком большой" }
        val output = ByteArrayOutputStream()
        body.byteStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var total = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                require(total <= MAX_JSON_RESPONSE_SIZE) { "Ответ сервера слишком большой" }
                output.write(buffer, 0, read)
            }
        }
        return output.toString(Charsets.UTF_8.name())
    }

    @Synchronized
    private fun scheduleReconnect(requestGeneration: Int) {
        if (!isCurrent(requestGeneration) || activeUsername.isBlank()) return
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        val delay = reconnectDelaySeconds
        reconnectDelaySeconds = (reconnectDelaySeconds * 2).coerceAtMost(60L)
        reconnectRunnable = Runnable {
            if (isCurrent(requestGeneration) && activeUsername.isNotBlank()) {
                login(activeUsername, activePassword)
            }
        }.also { mainHandler.postDelayed(it, TimeUnit.SECONDS.toMillis(delay)) }
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
            message.contains("invalid_credentials") ->
                "Чат: аккаунт $activeUsername ещё не синхронизирован с FreePBX"
            message.contains("unauthorized") -> "Чат: сессия истекла, войдите повторно"
            message.contains("contact_not_found") -> "Абонент не подключён к чату"
            message.contains("recipient_not_found") -> "SIP-номер получателя не найден"
            message.contains("cannot_message_yourself") -> "Нельзя написать самому себе"
            message.contains("cannot_call_yourself") -> "Нельзя позвонить самому себе"
            message.contains("video_unavailable") -> "Сервер видеозвонков временно недоступен"
            message.contains("call_not_found") -> "Видеозвонок уже завершён"
            message.contains("file_too_large") -> "Файл больше 20 МБ"
            message.contains("file_required") -> "Не удалось прочитать файл"
            message.contains("timeout", ignoreCase = true) -> "Чат: сервер не отвечает"
            message.contains("Unable to resolve host", ignoreCase = true) -> "Чат: нет подключения к интернету"
            message.contains("Failed to connect", ignoreCase = true) ||
                message.contains("Connection refused", ignoreCase = true) ->
                "Чат: сервер временно недоступен, повторяем подключение…"
            message.contains("HTTP 404") -> "Чат: сервер не нашёл получателя или диалог"
            message.contains("слишком большой", ignoreCase = true) -> message
            else -> "Чат: ${message.ifBlank { "ошибка подключения" }}"
        }
    }

    private data class AttachmentMetadata(
        val name: String,
        val mimeType: String,
        val size: Long
    )

    private class ChatApiException(val statusCode: Int, serverCode: String) :
        IllegalStateException(serverCode)

    private const val MAX_ATTACHMENT_SIZE = 20L * 1024 * 1024
    private const val MAX_JSON_RESPONSE_SIZE = 2L * 1024 * 1024
}
