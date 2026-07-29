package tj.tvoice.app

import android.content.Context

/** Read-only compatibility adapter for the pre-multi-account encrypted credential format. */
internal object CredentialStore {
    private const val PREFERENCES = "tvoice_secure_account"
    private const val USERNAME = "username"
    private const val PASSWORD = "password"
    private const val KEY_ALIAS = "tvoice_sip_account_key_v1"

    fun load(context: Context): Pair<String, String>? = runCatching {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val username = preferences.getString(USERNAME, null)?.takeIf { it.isNotBlank() } ?: return null
        val encoded = preferences.getString(PASSWORD, null) ?: return null
        username to AndroidKeystoreCipher.decrypt(KEY_ALIAS, encoded).toString(Charsets.UTF_8)
    }.getOrNull()

    fun clear(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().clear().apply()
    }
}
