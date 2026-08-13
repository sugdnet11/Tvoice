package tj.tvoice.app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

internal data class SipAccount(val username: String, val password: String)

/** Encrypted, process-independent storage for all user-approved SIP accounts. */
internal object AccountStore {
    private const val PREFERENCES = "tvoice_secure_accounts_v2"
    private const val PAYLOAD = "accounts"
    private const val KEY_ALIAS = "tvoice_sip_accounts_key_v2"

    @Synchronized
    fun load(context: Context): List<SipAccount> = runCatching {
        val encoded = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getString(PAYLOAD, null) ?: return migrateLegacy(context)
        val clear = AndroidKeystoreCipher.decrypt(KEY_ALIAS, encoded)
        val array = JSONArray(clear.toString(Charsets.UTF_8))
        buildList<SipAccount> {
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                val username = item.optString("username").trim()
                val password = item.optString("password")
                if (username.isNotBlank() && password.isNotBlank() && none { it.username == username }) {
                    add(SipAccount(username, password))
                }
            }
        }
    }.getOrDefault(emptyList())

    @Synchronized
    fun upsert(context: Context, account: SipAccount) {
        val normalized = account.copy(username = account.username.trim())
        require(normalized.username.isNotBlank() && normalized.password.isNotBlank())
        val accounts = load(context).filterNot { it.username == normalized.username } + normalized
        save(context, accounts)
    }

    @Synchronized
    fun remove(context: Context, username: String) {
        save(context, load(context).filterNot { it.username == username })
    }

    @Synchronized
    fun clear(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().clear().apply()
        CredentialStore.clear(context)
    }

    private fun save(context: Context, accounts: List<SipAccount>) {
        val array = JSONArray()
        accounts.distinctBy(SipAccount::username).forEach { account ->
            array.put(JSONObject().put("username", account.username).put("password", account.password))
        }
        val encoded = AndroidKeystoreCipher.encrypt(KEY_ALIAS, array.toString().toByteArray())
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putString(PAYLOAD, encoded).apply()
    }

    private fun migrateLegacy(context: Context): List<SipAccount> {
        val legacy = CredentialStore.load(context) ?: return emptyList()
        return listOf(SipAccount(legacy.first, legacy.second)).also {
            save(context, it)
            CredentialStore.clear(context)
        }
    }

}
