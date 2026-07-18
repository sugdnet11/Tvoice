package tj.tvoice.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Stores the active SIP password encrypted with a key that never leaves Android Keystore. */
internal object CredentialStore {
    private const val PREFERENCES = "tvoice_secure_account"
    private const val USERNAME = "username"
    private const val PASSWORD = "password"
    private const val KEY_ALIAS = "tvoice_sip_account_key_v1"

    fun save(context: Context, username: String, password: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.doFinal(password.toByteArray(Charsets.UTF_8))
        val payload = ByteArray(1 + cipher.iv.size + encrypted.size)
        payload[0] = cipher.iv.size.toByte()
        cipher.iv.copyInto(payload, 1)
        encrypted.copyInto(payload, 1 + cipher.iv.size)
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString(USERNAME, username)
            .putString(PASSWORD, Base64.encodeToString(payload, Base64.NO_WRAP))
            .apply()
    }

    fun load(context: Context): Pair<String, String>? = runCatching {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val username = preferences.getString(USERNAME, null)?.takeIf { it.isNotBlank() } ?: return null
        val payload = Base64.decode(preferences.getString(PASSWORD, null) ?: return null, Base64.NO_WRAP)
        val ivLength = payload.firstOrNull()?.toInt()?.and(0xff) ?: return null
        if (ivLength !in 12..16 || payload.size <= 1 + ivLength) return null
        val iv = payload.copyOfRange(1, 1 + ivLength)
        val encrypted = payload.copyOfRange(1 + ivLength, payload.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        username to cipher.doFinal(encrypted).toString(Charsets.UTF_8)
    }.getOrNull()

    fun username(context: Context): String? =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(USERNAME, null)

    fun clear(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().clear().apply()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
            generateKey()
        }
    }
}
