package ai.tos.mode

import ai.tos.mode.auth.SignIn
import ai.tos.mode.data.AppPrefs
import ai.tos.mode.data.CellClient
import ai.tos.mode.data.CellException
import ai.tos.mode.data.ModeApi
import ai.tos.mode.data.ModeRepository
import ai.tos.mode.data.Realtime
import ai.tos.mode.data.SessionStore
import android.app.Application
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import java.util.TimeZone
import java.util.concurrent.TimeUnit

class ModeApplication : Application(), SingletonImageLoader.Factory {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph(this)
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = graph.onForeground()
            override fun onStop(owner: LifecycleOwner) = graph.onBackground()
        })
    }

    override fun newImageLoader(context: Context): ImageLoader =
        ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { graph.http })) }
            .build()
}

/** The app's long-lived objects. Everything here runs on the main thread unless noted. */
class AppGraph(val app: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val prefs = AppPrefs(app)
    val sessions = SessionStore(app)
    val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()
    val cell = CellClient(http, sessions, BuildConfig.CELL_URL, BuildConfig.CELL_PUBLISHABLE_KEY, BuildConfig.VERSION_NAME)
    val api = ModeApi(cell)
    val realtime = Realtime(app, http, cell, sessions, BuildConfig.CELL_PUBLISHABLE_KEY, scope)
    val repo = ModeRepository(api, prefs, realtime, scope)
    val signIn = SignIn(cell, sessions, prefs)

    private var foreground = false

    init {
        cell.onSessionEnded = { scope.launch { signOutLocally() } }
        if (sessions.current != null) scope.launch { afterSignIn(fresh = false) }
    }

    fun onForeground() {
        foreground = true
        if (sessions.current == null) return
        realtime.hold(HOLD_APP)
        // A REST snapshot on every resume; realtime keeps it live from there.
        repo.refreshAll()
    }

    fun onBackground() {
        foreground = false
        realtime.release(HOLD_APP)
    }

    /** Brings the app up for a session that was just stored (or found at launch). */
    fun completeSignIn() {
        realtime.reset()
        scope.launch { afterSignIn(fresh = true) }
        if (foreground) realtime.hold(HOLD_APP)
        repo.refreshAll()
    }

    private suspend fun afterSignIn(fresh: Boolean) {
        // Profile (display name and photo change on Accounts).
        try {
            sessions.updateUser(cell.user())
        } catch (e: CellException) {
            Log.i(TAG, "Profile refresh failed: ${e.code}")
        }
        // Register this phone, so answers carry who sent them (`answers.answered_by`).
        if (fresh || prefs.phoneDeviceId == null) {
            try {
                prefs.phoneDeviceId = api.registerPhone(
                    installId = prefs.installId,
                    name = deviceName,
                    model = Build.MODEL,
                    osVersion = "Android ${Build.VERSION.RELEASE}",
                    appVersion = BuildConfig.VERSION_NAME,
                    timezone = TimeZone.getDefault().id,
                )
            } catch (e: CellException) {
                Log.i(TAG, "Phone registration failed: ${e.code}")
            }
        }
    }

    /** "Shubham's Pixel" when the person named the phone, else its model. */
    val deviceName: String
        get() = runCatching { Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
            ?.takeIf { it.isNotBlank() } ?: Build.MODEL

    /** Signs out on the cell (best effort) and locally. */
    suspend fun signOut() {
        prefs.phoneDeviceId?.let { id -> runCatching { api.revokePhone(id) } }
        runCatching { cell.signOut() }
        signOutLocally()
    }

    fun signOutLocally() {
        sessions.clear()
        prefs.clearAccountState()
        repo.clear()
        realtime.reset()
        realtime.release(HOLD_APP)
    }

    private companion object {
        const val TAG = "SiliconMode"
        const val HOLD_APP = "app"
    }
}

val Context.graph: AppGraph get() = (applicationContext as ModeApplication).graph
