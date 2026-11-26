package ai.tos.mode.ui

import ai.tos.mode.auth.SignIn
import ai.tos.mode.graph
import ai.tos.mode.ui.theme.SiliconTheme
import ai.tos.mode.ui.theme.isDark
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val g = graph
        setContent {
            val appearance by g.prefs.appearance.collectAsStateWithLifecycle()
            val dark = isDark(appearance)
            LaunchedEffect(dark) {
                val transparent = android.graphics.Color.TRANSPARENT
                val style = if (dark) SystemBarStyle.dark(transparent) else SystemBarStyle.light(transparent, transparent)
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
            }
            SiliconTheme(dark) {
                AppRoot(g, onSignIn = ::startSignIn)
            }
        }
        // A recreated activity gets its launch intent again; it was handled the first time.
        if (savedInstanceState == null) handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun startSignIn() {
        val signIn = graph.signIn
        signIn.message.value = signIn.start(this)
    }

    private fun handle(intent: Intent?) {
        val data = intent?.data ?: return
        if (intent.action != Intent.ACTION_VIEW) return
        val g = graph
        val signIn = g.signIn
        if (!signIn.isCallback(data)) return
        // Browsers add BROWSABLE to every intent a web page opens (adb's `am start` doesn't).
        val viaBrowser = intent.hasCategory(Intent.CATEGORY_BROWSABLE)
        signIn.busy.value = true
        signIn.message.value = null
        // The app scope, not the activity's: storing the session must finish even if this
        // activity is recreated meanwhile.
        g.scope.launch {
            try {
                when (val result = signIn.complete(data, viaBrowser)) {
                    SignIn.Result.Success -> g.completeSignIn()
                    is SignIn.Result.Failure -> signIn.message.value = result.message
                    SignIn.Result.Cancelled -> Unit
                    SignIn.Result.NotOurs -> Unit
                }
            } finally {
                signIn.busy.value = false
            }
        }
        // Tokens must not linger in the activity's intent.
        setIntent(Intent(this, MainActivity::class.java))
    }
}
