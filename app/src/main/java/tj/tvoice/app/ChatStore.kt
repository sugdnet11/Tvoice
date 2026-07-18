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
    val status: String
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
                    status = if (storedStatus == "sending") "failed" else storedStatus
                )
            }
        }
    }

    @Synchronized
    fun addOutgoing(owner: String, peer: String, text: String): ChatMessage = add(owner, peer, text, false, "sending")

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

    private fun add(owner: String, peer: String, text: String, incoming: Boolean, status: String): ChatMessage {
        val item = ChatMessage(
            id = System.currentTimeMillis() * 1000 + (messages.size % 1000),
            owner = owner,
            peer = peer,
            text = text,
            incoming = incoming,
            timestamp = System.currentTimeMillis(),
            status = status
        )
        messages += item
        while (messages.size > MAX_MESSAGES) messages.removeAt(0)
        persist()
        return item
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
            })
        }
        appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit().putString(KEY_MESSAGES, array.toString()).apply()
    }
}
