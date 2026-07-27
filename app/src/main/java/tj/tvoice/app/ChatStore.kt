package tj.tvoice.app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class ChatMessage(
    val id: Long,
    val owner: String,
    val peer: String,
    val text: String,
    val incoming: Boolean,
    val timestamp: Long,
    val status: String,
    val attachmentId: String? = null,
    val attachmentName: String? = null,
    val attachmentMime: String? = null,
    val attachmentSize: Long = 0
)

data class ChatConversation(
    val peer: String,
    val preview: String,
    val timestamp: Long,
    val unread: Int
)

/** Keeps a small local history so conversations survive process restarts. */
object ChatStore {
    private const val PREFERENCES = "tvoice_chat_v1"
    private const val KEY_MESSAGES = "messages"
    private const val MAX_MESSAGES = 500
    private val messages = mutableListOf<ChatMessage>()
    private var context: Context? = null

    @Synchronized
    fun initialize(value: Context) {
        if (context != null) return
        context = value.applicationContext
        val raw = context?.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            ?.getString(KEY_MESSAGES, null) ?: return
        runCatching {
            val array = JSONArray(raw)
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                val storedStatus = item.optString("status", "sent")
                messages += ChatMessage(
                    id = item.optLong("id"),
                    owner = item.optString("owner"),
                    peer = item.optString("peer"),
                    text = item.optString("text"),
                    incoming = item.optBoolean("incoming"),
                    timestamp = item.optLong("timestamp"),
                    status = if (storedStatus == "sending") "failed" else storedStatus,
                    attachmentId = item.optString("attachmentId").takeIf(String::isNotBlank),
                    attachmentName = item.optString("attachmentName").takeIf(String::isNotBlank),
                    attachmentMime = item.optString("attachmentMime").takeIf(String::isNotBlank),
                    attachmentSize = item.optLong("attachmentSize")
                )
            }
        }
    }

    @Synchronized
    fun addOutgoing(owner: String, peer: String, text: String): ChatMessage = add(owner, peer, text, false, "sending")

    @Synchronized
    fun addOutgoingAttachment(
        owner: String,
        peer: String,
        name: String,
        mimeType: String,
        size: Long
    ): ChatMessage = add(
        owner = owner,
        peer = peer,
        text = name,
        incoming = false,
        status = "sending",
        attachmentName = name,
        attachmentMime = mimeType,
        attachmentSize = size
    )

    @Synchronized
    fun addIncoming(owner: String, peer: String, text: String): ChatMessage = add(owner, peer, text, true, "received")

    @Synchronized
    fun markLatest(owner: String, peer: String, text: String, delivered: Boolean) {
        val index = messages.indexOfLast { !it.incoming && it.owner == owner && it.peer == peer && it.text == text && it.status == "sending" }
        if (index < 0) return
        messages[index] = messages[index].copy(status = if (delivered) "sent" else "failed")
        persist()
    }

    @Synchronized
    fun confirmOutgoing(
        owner: String,
        peer: String,
        text: String,
        serverId: Long,
        timestamp: Long,
        attachmentId: String? = null,
        attachmentName: String? = null,
        attachmentMime: String? = null,
        attachmentSize: Long = 0
    ): ChatMessage {
        val placeholderIndex = messages.indexOfLast {
            !it.incoming && it.owner == owner && it.peer == peer &&
                it.text == text && it.status == "sending"
        }
        val serverIndex = messages.indexOfFirst {
            it.owner == owner && it.peer == peer && it.id == serverId
        }
        val confirmed = ChatMessage(
            id = serverId,
            owner = owner,
            peer = peer,
            text = text,
            incoming = false,
            timestamp = timestamp,
            status = "sent",
            attachmentId = attachmentId,
            attachmentName = attachmentName,
            attachmentMime = attachmentMime,
            attachmentSize = attachmentSize
        )
        when {
            serverIndex >= 0 -> {
                messages[serverIndex] = confirmed
                if (placeholderIndex >= 0 && placeholderIndex != serverIndex) {
                    messages.removeAt(placeholderIndex)
                }
            }
            placeholderIndex >= 0 -> messages[placeholderIndex] = confirmed
            else -> messages += confirmed
        }
        trimAndPersist()
        return confirmed
    }

    @Synchronized
    fun upsertServer(
        owner: String,
        peer: String,
        serverId: Long,
        text: String,
        incoming: Boolean,
        timestamp: Long,
        attachmentId: String? = null,
        attachmentName: String? = null,
        attachmentMime: String? = null,
        attachmentSize: Long = 0
    ): ChatMessage {
        val index = messages.indexOfFirst {
            it.owner == owner && it.peer == peer && it.id == serverId
        }
        val existingStatus = messages.getOrNull(index)?.status
        val item = ChatMessage(
            id = serverId,
            owner = owner,
            peer = peer,
            text = text,
            incoming = incoming,
            timestamp = timestamp,
            status = if (incoming && existingStatus == "read") "read" else if (incoming) "received" else "sent",
            attachmentId = attachmentId,
            attachmentName = attachmentName,
            attachmentMime = attachmentMime,
            attachmentSize = attachmentSize
        )
        if (index >= 0) messages[index] = item else messages += item
        trimAndPersist()
        return item
    }

    @Synchronized
    fun failSending() {
        var changed = false
        messages.indices.forEach { index ->
            if (messages[index].status == "sending") {
                messages[index] = messages[index].copy(status = "failed")
                changed = true
            }
        }
        if (changed) persist()
    }

    @Synchronized
    fun messages(owner: String, peer: String): List<ChatMessage> =
        messages.filter { it.owner == owner && it.peer == peer }.sortedBy { it.timestamp }

    @Synchronized
    fun conversations(owner: String): List<ChatConversation> = messages
        .filter { it.owner == owner }
        .groupBy { it.peer }
        .mapNotNull { (peer, values) ->
            values.maxByOrNull { it.timestamp }?.let { last ->
                ChatConversation(peer, last.text, last.timestamp, values.count { it.incoming && it.status == "received" })
            }
        }
        .sortedByDescending { it.timestamp }

    @Synchronized
    fun markRead(owner: String, peer: String) {
        var changed = false
        messages.indices.forEach { index ->
            val item = messages[index]
            if (item.owner == owner && item.peer == peer && item.incoming && item.status == "received") {
                messages[index] = item.copy(status = "read")
                changed = true
            }
        }
        if (changed) persist()
    }

    private fun add(
        owner: String,
        peer: String,
        text: String,
        incoming: Boolean,
        status: String,
        attachmentName: String? = null,
        attachmentMime: String? = null,
        attachmentSize: Long = 0
    ): ChatMessage {
        val item = ChatMessage(
            id = System.currentTimeMillis() * 1000 + (messages.size % 1000),
            owner = owner,
            peer = peer,
            text = text,
            incoming = incoming,
            timestamp = System.currentTimeMillis(),
            status = status,
            attachmentName = attachmentName,
            attachmentMime = attachmentMime,
            attachmentSize = attachmentSize
        )
        messages += item
        trimAndPersist()
        return item
    }

    private fun trimAndPersist() {
        while (messages.size > MAX_MESSAGES) messages.removeAt(0)
        persist()
    }

    private fun persist() {
        val appContext = context ?: return
        val array = JSONArray()
        messages.forEach { item ->
            array.put(JSONObject().apply {
                put("id", item.id)
                put("owner", item.owner)
                put("peer", item.peer)
                put("text", item.text)
                put("incoming", item.incoming)
                put("timestamp", item.timestamp)
                put("status", item.status)
                put("attachmentId", item.attachmentId ?: "")
                put("attachmentName", item.attachmentName ?: "")
                put("attachmentMime", item.attachmentMime ?: "")
                put("attachmentSize", item.attachmentSize)
            })
        }
        appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit().putString(KEY_MESSAGES, array.toString()).apply()
    }
}
