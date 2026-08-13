package tj.tvoice.app

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Small AES-GCM envelope backed by a non-exportable Android Keystore key. */
internal object AndroidKeystoreCipher {
    fun encrypt(keyAlias: String, clear: ByteArray): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey(keyAlias))
        val encrypted = cipher.doFinal(clear)
        val payload = byteArrayOf(cipher.iv.size.toByte()) + cipher.iv + encrypted
        return Base64.encodeToString(payload, Base64.NO_WRAP)
    }

    fun decrypt(keyAlias: String, encoded: String): ByteArray {
        val payload = Base64.decode(encoded, Base64.NO_WRAP)
        val ivSize = payload.firstOrNull()?.toInt()?.and(0xff) ?: error("Empty encrypted payload")
        require(ivSize in 12..16 && payload.size > ivSize + 1) { "Invalid encrypted payload" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(keyAlias),
            GCMParameterSpec(128, payload.copyOfRange(1, ivSize + 1))
        )
        return cipher.doFinal(payload.copyOfRange(ivSize + 1, payload.size))
    }

    @Synchronized
    private fun secretKey(keyAlias: String): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    keyAlias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
            generateKey()
        }
    }

    private const val TRANSFORMATION = "AES/GCM/NoPadding"
}
