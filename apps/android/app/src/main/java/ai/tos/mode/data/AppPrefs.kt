package ai.tos.mode.data

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

enum class Appearance { System, Light, Dark }

/** Non-secret preferences (the session itself lives in [SessionStore]). */
class AppPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("mode-prefs", Context.MODE_PRIVATE)

    private val _appearance = MutableStateFlow(
        runCatching { Appearance.valueOf(prefs.getString(KEY_APPEARANCE, null) ?: "System") }.getOrDefault(Appearance.System),
    )
    val appearance: StateFlow<Appearance> = _appearance.asStateFlow()

    fun setAppearance(value: Appearance) {
        prefs.edit { putString(KEY_APPEARANCE, value.name) }
        _appearance.value = value
    }

    /** The Mac the person last looked at, so the app reopens on it. */
    var selectedDeviceId: String?
        get() = prefs.getString(KEY_SELECTED, null)
        set(value) = prefs.edit { if (value == null) remove(KEY_SELECTED) else putString(KEY_SELECTED, value) }

    /** Random per install; identifies this phone to `rpc/register_device`. */
    val installId: String
        get() = prefs.getString(KEY_INSTALL, null) ?: UUID.randomUUID().toString().lowercase().also {
            prefs.edit(commit = true) { putString(KEY_INSTALL, it) }
        }

    /** This phone's `devices.id` once registered (sent as `p_by` with answers). */
    var phoneDeviceId: String?
        get() = prefs.getString(KEY_PHONE_DEVICE, null)
        set(value) = prefs.edit { if (value == null) remove(KEY_PHONE_DEVICE) else putString(KEY_PHONE_DEVICE, value) }

    /** When the person last started a sign-in from this app (epoch ms), to reject unsolicited callbacks. */
    var pendingSignInAt: Long
        get() = prefs.getLong(KEY_PENDING, 0L)
        set(value) = prefs.edit(commit = true) { putLong(KEY_PENDING, value) }

    fun clearAccountState() {
        prefs.edit(commit = true) {
            remove(KEY_SELECTED)
            remove(KEY_PHONE_DEVICE)
            remove(KEY_PENDING)
        }
    }

    private companion object {
        const val KEY_APPEARANCE = "appearance"
        const val KEY_SELECTED = "selected_device"
        const val KEY_INSTALL = "install_id"
        const val KEY_PHONE_DEVICE = "phone_device_id"
        const val KEY_PENDING = "pending_sign_in_at"
    }
}
