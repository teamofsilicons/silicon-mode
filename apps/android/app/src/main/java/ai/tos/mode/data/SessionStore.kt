package ai.tos.mode.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * A Silicon Cell session (docs/research/cells.md §2): a short-lived EdDSA access JWT (≤ 30 min)
 * and a single-use `csr_…` refresh token that rotates on every refresh.
 */
@Serializable
data class CellSession(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
    /** Unix seconds. */
    @SerialName("expires_at") val expiresAt: Long,
    val user: CellUser? = null,
) {
    fun secondsLeft(nowMs: Long = System.currentTimeMillis()): Long = expiresAt - nowMs / 1000
}

/**
 * Keeps the cell session sealed with a non-exportable AES-GCM key in the Android Keystore (the
 * Silicon Ring pattern). The ciphertext lives in private shared preferences; nothing here is ever
 * backed up (allowBackup=false, data_extraction_rules).
 */
class SessionStore(context: Context) {
    private val prefs = context.getSharedPreferences("mode-session", Context.MODE_PRIVATE)
    private val _session = MutableStateFlow(load())
    val session: StateFlow<CellSession?> = _session.asStateFlow()

    val current: CellSession? get() = _session.value

    @Synchronized
    fun save(value: CellSession) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val plain = ModeJson.encodeToString(CellSession.serializer(), value).toByteArray(Charsets.UTF_8)
        val sealed = cipher.doFinal(plain)
        prefs.edit(commit = true) {
            putString(KEY_IV, Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            putString(KEY_SESSION, Base64.encodeToString(sealed, Base64.NO_WRAP))
        }
        _session.value = value
    }

    fun updateUser(user: CellUser) {
        val existing = _session.value ?: return
        if (existing.user != user) save(existing.copy(user = user))
    }

    @Synchronized
    fun clear() {
        prefs.edit(commit = true) { clear() }
        _session.value = null
    }

    private fun load(): CellSession? {
        val sealed = prefs.getString(KEY_SESSION, null) ?: return null
        val iv = prefs.getString(KEY_IV, null) ?: return null
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            val plain = cipher.doFinal(Base64.decode(sealed, Base64.NO_WRAP)).toString(Charsets.UTF_8)
            ModeJson.decodeFromString(CellSession.serializer(), plain)
        } catch (e: Exception) {
            // A lost Keystore key (for example after a restore) leaves an unreadable blob: start over.
            Log.w(TAG, "Stored session could not be opened; signing out (${e.javaClass.simpleName})")
            prefs.edit(commit = true) { clear() }
            null
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val TAG = "ModeSession"
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "silicon-mode-session"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val KEY_IV = "iv"
        const val KEY_SESSION = "session"
    }
}
