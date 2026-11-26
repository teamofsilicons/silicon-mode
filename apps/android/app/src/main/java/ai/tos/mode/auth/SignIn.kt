package ai.tos.mode.auth

import ai.tos.mode.BuildConfig
import ai.tos.mode.data.AppPrefs
import ai.tos.mode.data.CellClient
import ai.tos.mode.data.CellException
import ai.tos.mode.data.CellSession
import ai.tos.mode.data.SessionStore
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.verify.domain.DomainVerificationManager
import android.content.pm.verify.domain.DomainVerificationUserState
import android.net.Uri
import android.os.Build
import androidx.browser.customtabs.CustomTabColorSchemeParams
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.graphics.toColorInt
import kotlinx.coroutines.flow.MutableStateFlow
import java.net.URLDecoder

/** What the sign-in redirect carried. Pure (no Android types) so it is unit tested. */
sealed interface CallbackResult {
    data class Tokens(val accessToken: String, val refreshToken: String, val expiresAt: Long) : CallbackResult
    data class Denied(val error: String) : CallbackResult
    data object Malformed : CallbackResult
}

object CallbackParser {
    /**
     * Parses `#access_token=…&refresh_token=csr_…&expires_at=<unix>` (token mode) or
     * `?error=access_denied` from the redirect's [fragment] / [query].
     */
    fun parse(fragment: String?, query: String?): CallbackResult {
        val params = decode(fragment) + decode(query)
        params["error"]?.let { return CallbackResult.Denied(it) }
        val access = params["access_token"]?.takeIf { it.isNotBlank() } ?: return CallbackResult.Malformed
        val refresh = params["refresh_token"]?.takeIf { it.isNotBlank() } ?: return CallbackResult.Malformed
        val expiresAt = params["expires_at"]?.toLongOrNull()
            ?: params["expires_in"]?.toLongOrNull()?.let { System.currentTimeMillis() / 1000 + it }
            ?: (System.currentTimeMillis() / 1000 + 1800)
        return CallbackResult.Tokens(access, refresh, expiresAt)
    }

    private fun decode(raw: String?): Map<String, String> {
        if (raw.isNullOrBlank()) return emptyMap()
        return raw.removePrefix("#").removePrefix("?").split('&').mapNotNull { pair ->
            if (pair.isEmpty()) return@mapNotNull null
            val i = pair.indexOf('=')
            val key = if (i < 0) pair else pair.substring(0, i)
            val value = if (i < 0) "" else pair.substring(i + 1)
            // Fragments are not form-encoded: a literal '+' stays a '+'.
            fun dec(s: String) = URLDecoder.decode(s.replace("+", "%2B"), "UTF-8")
            runCatching { dec(key) to dec(value) }.getOrNull()
        }.toMap()
    }
}

/**
 * Where a sign-in's tokens may go. The cell redirects to the https App Link; until Android has
 * verified it (`/.well-known/assetlinks.json`), the page there forwards the tokens to
 * `ai.tos.mode://auth/callback`, a scheme any installed app can also claim. Pure, so it is unit tested.
 */
object CallbackChannel {
    /** Why a sign-in must not start, or null when the tokens can only reach this app. */
    fun refusal(appLinkVerified: Boolean, otherHandlers: List<String>): String? {
        if (appLinkVerified || otherHandlers.isEmpty()) return null
        val who = otherHandlers.distinct().take(2).joinToString(" and ")
        return "$who also opens Silicon Mode's sign-in link, so it could receive your session. " +
            "Uninstall it, then sign in again."
    }
}

/**
 * Hosted Silicon Cell sign-in (docs/research/cells.md §2.3): a Custom Tab opens
 * `/auth/sign-in?redirect_to=https://mode.teamofsilicons.com/auth/android&session=token&app=silicon-mode`;
 * the cell runs Silicon Accounts (PKCE between cell and Accounts) and redirects with the tokens in
 * the URL fragment; the bounce page forwards them to `ai.tos.mode://auth/callback#…`
 * (or Android delivers the https App Link directly once assetlinks.json is served). Sign-in won't
 * start while another app also claims that scheme and the App Link isn't verified ([CallbackChannel]).
 */
class SignIn(
    private val cell: CellClient,
    private val sessions: SessionStore,
    private val prefs: AppPrefs,
) {
    val busy = MutableStateFlow(false)
    val message = MutableStateFlow<String?>(null)

    fun signInUrl(): Uri = Uri.parse(BuildConfig.CELL_URL.trimEnd('/') + "/auth/sign-in").buildUpon()
        .appendQueryParameter("redirect_to", BuildConfig.SIGN_IN_REDIRECT)
        .appendQueryParameter("session", "token")
        .appendQueryParameter("app", BuildConfig.CELL_APP)
        .build()

    /** Opens the sign-in page. Returns an error message, or null when the page opened. */
    fun start(context: Context): String? {
        // Bearer tokens must not go where another app can take them.
        CallbackChannel.refusal(appLinkVerified(context), otherCallbackHandlers(context))?.let { return it }
        prefs.pendingSignInAt = System.currentTimeMillis()
        val light = CustomTabColorSchemeParams.Builder()
            .setToolbarColor("#FCFCFC".toColorInt())
            .setNavigationBarColor("#FCFCFC".toColorInt())
            .build()
        val dark = CustomTabColorSchemeParams.Builder()
            .setToolbarColor("#141414".toColorInt())
            .setNavigationBarColor("#141414".toColorInt())
            .build()
        return try {
            CustomTabsIntent.Builder()
                .setDefaultColorSchemeParams(light)
                .setColorSchemeParams(CustomTabsIntent.COLOR_SCHEME_DARK, dark)
                .setShowTitle(true)
                .setShareState(CustomTabsIntent.SHARE_STATE_OFF)
                .build()
                .launchUrl(context, signInUrl())
            null
        } catch (e: ActivityNotFoundException) {
            "Install a web browser to sign in with Silicon Accounts."
        }
    }

    /** Whether Android opens [BuildConfig.SIGN_IN_REDIRECT] in this app (verified, or chosen by the person). */
    private fun appLinkVerified(context: Context): Boolean {
        val redirect = Uri.parse(BuildConfig.SIGN_IN_REDIRECT)
        val host = redirect.host ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = context.getSystemService(DomainVerificationManager::class.java) ?: return false
            val state = runCatching { manager.getDomainVerificationUserState(context.packageName) }.getOrNull() ?: return false
            return when (state.hostToStateMap[host]) {
                DomainVerificationUserState.DOMAIN_STATE_VERIFIED, DomainVerificationUserState.DOMAIN_STATE_SELECTED -> true
                else -> false
            }
        }
        // No verification API before Android 12: the link resolving to this app by default is the same signal.
        val intent = Intent(Intent.ACTION_VIEW, redirect).addCategory(Intent.CATEGORY_BROWSABLE)
        @Suppress("DEPRECATION")
        val handler = context.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        return handler?.activityInfo?.packageName == context.packageName
    }

    /** Other installed apps that would be offered `ai.tos.mode://auth/callback` (visible through `<queries>`). */
    private fun otherCallbackHandlers(context: Context): List<String> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("$SCHEME://auth/callback")).addCategory(Intent.CATEGORY_BROWSABLE)
        val matches = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()))
            } else {
                @Suppress("DEPRECATION")
                pm.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            }
        }.getOrDefault(emptyList())
        return matches.filter { it.activityInfo.packageName != context.packageName }
            .map { runCatching { it.loadLabel(pm).toString() }.getOrDefault(it.activityInfo.packageName) }
    }

    sealed interface Result {
        data object Success : Result
        data class Failure(val message: String) : Result
        data object Cancelled : Result
        data object NotOurs : Result
    }

    fun isCallback(uri: Uri): Boolean =
        (uri.scheme == SCHEME && uri.host == "auth" && uri.path == "/callback") ||
            (uri.scheme == "https" && uri.host == Uri.parse(BuildConfig.SIGN_IN_REDIRECT).host &&
                uri.path == Uri.parse(BuildConfig.SIGN_IN_REDIRECT).path)

    /**
     * Completes sign-in from the redirect [uri]: validates the tokens with `/auth/user`, then stores
     * them. [viaBrowser]: a web page opened it (the intent carries `CATEGORY_BROWSABLE`).
     */
    suspend fun complete(uri: Uri, viaBrowser: Boolean): Result {
        if (!isCallback(uri)) return Result.NotOurs
        // A callback nobody asked for could sign this phone into someone else's account: accept one
        // only shortly after the person tapped "Continue". Debug builds also take one delivered over
        // adb (docs/ANDROID.md, testing without a browser), but never one a web page opened.
        if (!acceptsCallback(prefs.pendingSignInAt, System.currentTimeMillis(), BuildConfig.DEBUG, viaBrowser)) {
            return Result.Failure("This sign-in link has expired. Try again.")
        }
        return when (val parsed = CallbackParser.parse(uri.encodedFragment, uri.encodedQuery)) {
            is CallbackResult.Denied -> {
                prefs.pendingSignInAt = 0
                if (parsed.error == "access_denied") Result.Cancelled else Result.Failure("Sign-in failed (${parsed.error}).")
            }
            CallbackResult.Malformed -> Result.Failure("Silicon Accounts did not return a session. Try again.")
            is CallbackResult.Tokens -> try {
                val user = cell.user(parsed.accessToken)
                // Signing in again replaces the current session: end the old one on the cell first.
                if (sessions.current != null && sessions.current?.refreshToken != parsed.refreshToken) cell.signOut()
                sessions.save(CellSession(parsed.accessToken, parsed.refreshToken, parsed.expiresAt, user))
                prefs.pendingSignInAt = 0
                Result.Success
            } catch (e: CellException) {
                Result.Failure(if (e.isNetwork) e.userMessage else "That session was not accepted (${e.code}). Try again.")
            }
        }
    }

    companion object {
        const val SCHEME = "ai.tos.mode"
        const val PENDING_WINDOW_MS = 15 * 60 * 1000L

        /** Whether a sign-in callback may be taken: one started here recently, or adb on a debug build. */
        fun acceptsCallback(pendingSignInAt: Long, nowMs: Long, debugBuild: Boolean, viaBrowser: Boolean): Boolean {
            val fresh = pendingSignInAt > 0 && nowMs - pendingSignInAt in 0 until PENDING_WINDOW_MS
            return fresh || (debugBuild && !viaBrowser)
        }
    }
}
