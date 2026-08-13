package tj.tvoice.app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class CallHistoryItem(
    val number: String,
    val direction: String,
    val time: String,
    var durationSeconds: Long = 0,
    val timestampMillis: Long = System.currentTimeMillis()
)

internal interface CallHistoryRepository {
    fun load(): List<CallHistoryItem>
    fun save(items: List<CallHistoryItem>)
}

internal class CallHistoryStore(context: Context) : CallHistoryRepository {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    @Synchronized
    override fun load(): List<CallHistoryItem> = runCatching {
        val encoded = preferences.getString(KEY, null)
        val legacy = if (encoded == null) legacyPayload() else null
        val raw = encoded?.let { AndroidKeystoreCipher.decrypt(KEY_ALIAS, it).toString(Charsets.UTF_8) }
            ?: legacy?.third
            ?: "[]"
        val array = JSONArray(raw)
        val items = List(array.length()) { index ->
            val item = array.getJSONObject(index)
            CallHistoryItem(
                item.optString("number"),
                item.optString("direction"),
                item.optString("time"),
                item.optLong("duration"),
                item.optLong("timestampMillis").takeIf { it > 0 } ?: System.currentTimeMillis()
            )
        }
        if (legacy != null) {
            save(items)
            legacy.first.edit().remove(legacy.second).apply()
        }
        items
    }.getOrDefault(emptyList())

    @Synchronized
    override fun save(items: List<CallHistoryItem>) {
        val array = JSONArray()
        items.take(MAX_ITEMS).forEach { item ->
            array.put(
                JSONObject().put("number", item.number)
                    .put("direction", item.direction)
                    .put("time", item.time)
                    .put("duration", item.durationSeconds)
                    .put("timestampMillis", item.timestampMillis)
            )
        }
        val encoded = AndroidKeystoreCipher.encrypt(KEY_ALIAS, array.toString().toByteArray())
        preferences.edit().putString(KEY, encoded).apply()
    }

    private fun legacyPayload(): Triple<android.content.SharedPreferences, String, String>? {
        val candidates = listOf(
            appContext.getSharedPreferences("tvoice_call_history_v2", Context.MODE_PRIVATE) to listOf("history"),
            appContext.getSharedPreferences("tvoice", Context.MODE_PRIVATE) to listOf("call_history", "history")
        )
        candidates.forEach { (store, keys) ->
            keys.forEach { key ->
                store.getString(key, null)?.let { return Triple(store, key, it) }
            }
        }
        return null
    }

    private companion object {
        const val PREFERENCES = "tvoice_secure_call_history_v3"
        const val KEY = "history"
        const val KEY_ALIAS = "tvoice_call_history_key_v3"
        const val MAX_ITEMS = 100
    }
}

/** Keeps call-history session rules out of the Activity and makes them unit-testable. */
internal class CallHistoryTracker(private val repository: CallHistoryRepository) {
    val items = mutableListOf<CallHistoryItem>()
    private var active: CallHistoryItem? = null
    private var connectedAtMillis: Long? = null
    private var loaded = false

    fun load() {
        if (loaded) return
        loaded = true
        items += repository.load()
    }

    fun begin(number: String, direction: String, displayTime: String) {
        if (active != null) return
        connectedAtMillis = null
        active = CallHistoryItem(number, direction, displayTime).also { items.add(0, it) }
        repository.save(items)
    }

    fun markConnected(atMillis: Long) {
        if (active != null && connectedAtMillis == null) connectedAtMillis = atMillis
    }

    fun finish(atMillis: Long) {
        val item = active ?: return
        connectedAtMillis?.let { started ->
            item.durationSeconds = ((atMillis - started) / 1_000L).coerceAtLeast(1L)
        }
        connectedAtMillis = null
        active = null
        repository.save(items)
    }
}
