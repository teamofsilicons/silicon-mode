package ai.tos.mode.ui.settings

import ai.tos.mode.BuildConfig
import ai.tos.mode.data.Appearance
import ai.tos.mode.data.CellUser
import ai.tos.mode.data.MacItem
import ai.tos.mode.data.Realtime
import ai.tos.mode.ui.Format
import ai.tos.mode.ui.components.Avatar
import ai.tos.mode.ui.components.ButtonKind
import ai.tos.mode.ui.components.Eyebrow
import ai.tos.mode.ui.components.Hairline
import ai.tos.mode.ui.components.IconBubble
import ai.tos.mode.ui.components.PulseDot
import ai.tos.mode.ui.components.Segmented
import ai.tos.mode.ui.components.SiButton
import ai.tos.mode.ui.components.SiCard
import ai.tos.mode.ui.rememberNow
import ai.tos.mode.ui.theme.SiIcons
import ai.tos.mode.ui.theme.Silicon
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.SmoothShape
import ai.tos.mode.ui.theme.pressable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

data class SettingsData(
    val user: CellUser?,
    val macs: List<MacItem>,
    val appearance: Appearance,
    val live: Realtime.Status,
    val phoneName: String,
)

@Composable
fun SettingsScreen(
    data: SettingsData,
    contentPadding: PaddingValues,
    onAppearance: (Appearance) -> Unit,
    onSignOut: () -> Unit,
    onOpenUrl: (String) -> Unit,
) {
    val c = Silicon.colors
    val now by rememberNow(30_000)
    var confirm by rememberSaveable { mutableStateOf(false) }

    LazyColumn(contentPadding = contentPadding, verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxSize()) {
        item(key = "title") {
            Column(Modifier.padding(start = 4.dp, end = 4.dp, top = 6.dp, bottom = 2.dp)) {
                Eyebrow("Settings")
                Spacer(Modifier.height(2.dp))
                Text("You & your Macs", style = SiliconType.display, color = c.foreground)
            }
        }
        item(key = "account") {
            SiCard(Modifier.fillMaxWidth(), padding = PaddingValues(18.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Avatar(data.user, 56.dp)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(data.user?.label ?: "Signed in", style = SiliconType.h2, color = c.foreground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        data.user?.id?.let { Text(it, style = SiliconType.mono, color = c.textMuted) }
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "Silicon account · " + when (data.user?.kind) { "silicon" -> "Silicon"; "carbon" -> "Carbon"; else -> "member" },
                            style = SiliconType.hint, color = c.textFaint,
                        )
                    }
                }
            }
        }
        item(key = "macs") {
            Group("Your Macs") {
                if (data.macs.isEmpty()) {
                    Text(
                        "No Macs yet. Sign in to Silicon Mode on a Mac with this account.",
                        style = SiliconType.small, color = c.textMuted, modifier = Modifier.padding(16.dp),
                    )
                }
                data.macs.forEachIndexed { i, mac ->
                    if (i > 0) Hairline(Modifier.padding(start = 60.dp))
                    val online = mac.status?.online == true && (Format.since(mac.status.updatedAt, now) ?: Long.MAX_VALUE) < 360
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconBubble(SiIcons.Laptop, c.textSecondary, c.surfaceMuted, 32.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(mac.device.name, style = SiliconType.label, color = c.foreground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(
                                listOfNotNull(Format.macModel(mac.device.model), mac.device.osVersion, mac.device.appVersion?.let { "app $it" }).joinToString(" · "),
                                style = SiliconType.hint, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            PulseDot(if (online) c.success else c.textFaint, pulsing = false, size = 6.dp)
                            Text(
                                if (online) "Online" else (mac.device.lastSeenAt?.let { Format.ago(it, now) }?.let { if (it == "now") "just now" else if (it == "yesterday") it else "$it ago" } ?: "—"),
                                style = SiliconType.caption, color = c.textMuted,
                            )
                        }
                    }
                }
            }
        }
        item(key = "appearance") {
            Group("Appearance") {
                Segmented(
                    options = listOf(Appearance.System to "System", Appearance.Light to "Light", Appearance.Dark to "Dark"),
                    selected = data.appearance,
                    onSelect = onAppearance,
                    modifier = Modifier.fillMaxWidth().padding(12.dp),
                )
            }
        }
        item(key = "connection") {
            Group("Connection") {
                val (color, label) = when (data.live) {
                    Realtime.Status.Live -> c.success to "Live"
                    Realtime.Status.Connecting -> c.warning to "Connecting…"
                    Realtime.Status.Offline -> c.textFaint to "Offline"
                }
                InfoRow(SiIcons.Activity, "Realtime") {
                    PulseDot(color, pulsing = data.live == Realtime.Status.Live, size = 6.dp)
                    Text(label, style = SiliconType.small, color = c.textSecondary)
                }
                Hairline(Modifier.padding(start = 60.dp))
                InfoRow(SiIcons.Terminal, "Backend") {
                    Text(BuildConfig.CELL_URL.removePrefix("https://"), style = SiliconType.hint, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Hairline(Modifier.padding(start = 60.dp))
                InfoRow(SiIcons.Phone, "This phone") {
                    Text(data.phoneName, style = SiliconType.small, color = c.textSecondary, maxLines = 1)
                }
            }
        }
        item(key = "about") {
            Group("About") {
                LinkRow(SiIcons.External, "Silicon Mode on the web", "mode.teamofsilicons.com") { onOpenUrl(BuildConfig.WEB_URL) }
                Hairline(Modifier.padding(start = 60.dp))
                LinkRow(SiIcons.External, "Source code", "github.com/teamofsilicons") { onOpenUrl(BuildConfig.SOURCE_URL) }
                Hairline(Modifier.padding(start = 60.dp))
                InfoRow(SiIcons.Bolt, "Version") {
                    Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", style = SiliconType.small.copy(fontFeatureSettings = "tnum"), color = c.textSecondary)
                }
            }
        }
        item(key = "signout") {
            SiButton(
                "Sign out",
                onClick = { confirm = true },
                kind = ButtonKind.Danger,
                icon = SiIcons.SignOut,
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
            )
        }
        item(key = "foot") {
            Text(
                "Allo typeface · SIL Open Font License. No analytics, no tracking.",
                style = SiliconType.hint, color = c.textFaint,
                modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }

    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            shape = SmoothShape(26.dp),
            containerColor = c.surfaceRaised,
            title = { Text("Sign out of Silicon Mode?", style = SiliconType.h2, color = c.foreground) },
            text = { Text("This phone stops showing your Macs and their agents until you sign in again.", style = SiliconType.small, color = c.textMuted) },
            confirmButton = {
                TextButton(onClick = { confirm = false; onSignOut() }) { Text("Sign out", style = SiliconType.label, color = c.danger) }
            },
            dismissButton = {
                TextButton(onClick = { confirm = false }) { Text("Cancel", style = SiliconType.label, color = c.textSecondary) }
            },
        )
    }
}

@Composable
private fun Group(title: String, content: @Composable () -> Unit) {
    val c = Silicon.colors
    Column {
        Text(title, style = SiliconType.caption, color = c.textMuted, modifier = Modifier.padding(start = 6.dp, bottom = 8.dp, top = 6.dp))
        SiCard(Modifier.fillMaxWidth(), elevation = 3.dp, padding = PaddingValues(0.dp)) {
            Column { content() }
        }
    }
}

@Composable
private fun InfoRow(icon: ImageVector, label: String, trailing: @Composable () -> Unit) {
    val c = Silicon.colors
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        IconBubble(icon, c.textSecondary, c.surfaceMuted, 32.dp)
        Spacer(Modifier.width(12.dp))
        Text(label, style = SiliconType.label, color = c.foreground, modifier = Modifier.weight(1f))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.End) { trailing() }
    }
}

@Composable
private fun LinkRow(icon: ImageVector, label: String, detail: String, onClick: () -> Unit) {
    val c = Silicon.colors
    Row(
        Modifier.fillMaxWidth().clip(SmoothShape(0.dp)).pressable(pressedScale = 0.99f, onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconBubble(icon, c.accent, c.accentSubtle, 32.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(label, style = SiliconType.label, color = c.foreground)
            Text(detail, style = SiliconType.hint, color = c.textMuted)
        }
        Icon(SiIcons.ChevronRight, null, tint = c.textFaint, modifier = Modifier.size(18.dp))
    }
}
