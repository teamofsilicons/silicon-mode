package ai.tos.mode

import ai.tos.mode.data.Liveness
import ai.tos.mode.data.ModeJson
import ai.tos.mode.data.RealtimeFrame
import ai.tos.mode.data.RealtimeSub
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RealtimeFrameTest {
    @Test
    fun parsesServerFrames() {
        assertEquals(RealtimeFrame.Ready("c1"), RealtimeFrame.parse("""{"type":"ready","connection_id":"c1"}"""))
        assertEquals(RealtimeFrame.Subscribed("answers:x", 12345), RealtimeFrame.parse("""{"type":"subscribed","id":"answers:x","cursor":12345}"""))
        assertEquals(RealtimeFrame.Pong, RealtimeFrame.parse("""{"type":"pong","nonce":1}"""))
        assertEquals(RealtimeFrame.Other, RealtimeFrame.parse("""{"type":"joined","channel":"x"}"""))
        val err = RealtimeFrame.parse("""{"type":"error","code":"cursor_expired","message":"m","id":"events:x"}""") as RealtimeFrame.Error
        assertEquals("cursor_expired", err.code)
        assertEquals("events:x", err.id)
    }

    @Test
    fun parsesChange() {
        val f = RealtimeFrame.parse(
            """{"type":"change","subscription":"events:d","event_id":"e1","schema":"public","table":"events",
               "operation":"INSERT","old":null,"new":{"id":7,"summary":"Bash: ls"},"occurred_at":"…","cursor":12346}""",
        ) as RealtimeFrame.Change
        assertEquals("e1", f.eventId)
        assertEquals(12346L, f.cursor)
        assertEquals("events", f.change.table)
        assertEquals("INSERT", f.change.operation)
        assertEquals(null, f.change.old)
        assertEquals("Bash: ls", f.change.new!!["summary"]!!.jsonPrimitive.content)
    }

    @Test
    fun aSilentSocketGoesStale() {
        val liveness = Liveness(staleAfterMs = 70_000)
        liveness.heard(1_000)
        assertFalse(liveness.isStale(1_000 + 25_000))   // one ping interval
        assertFalse(liveness.isStale(1_000 + 70_000))
        assertTrue(liveness.isStale(1_000 + 70_001))    // two pongs missed
        liveness.heard(80_000)                          // any frame (a pong) resets it
        assertFalse(liveness.isStale(100_000))
    }

    @Test
    fun buildsClientFrames() {
        val auth = ModeJson.parseToJsonElement(RealtimeFrame.authenticate("cs_publishable_k", "jwt")).jsonObject
        assertEquals("authenticate", auth["type"]!!.jsonPrimitive.content)
        assertEquals("jwt", auth["access_token"]!!.jsonPrimitive.content)

        val sub = RealtimeSub("answers:d", "answers", listOf("INSERT"), listOf(Triple("device_id", "eq", "d")))
        val withCursor = ModeJson.parseToJsonElement(RealtimeFrame.subscribe(sub, 42)).jsonObject
        assertEquals("subscribe", withCursor["type"]!!.jsonPrimitive.content)
        assertEquals("public", withCursor["schema"]!!.jsonPrimitive.content)
        assertEquals(42L, withCursor["after"]!!.jsonPrimitive.long)
        val filter = withCursor["filters"]!!.jsonArray[0].jsonObject
        assertEquals("device_id", filter["column"]!!.jsonPrimitive.content)
        assertEquals("eq", filter["op"]!!.jsonPrimitive.content)
        assertEquals("INSERT", withCursor["events"]!!.jsonArray[0].jsonPrimitive.content)

        val fresh = ModeJson.parseToJsonElement(RealtimeFrame.subscribe(RealtimeSub("device_status", "device_status"), null)).jsonObject
        assertFalse("after" in fresh)
        assertFalse("filters" in fresh)
        assertFalse("events" in fresh)
        assertTrue(RealtimeFrame.unsubscribe("x").contains("\"unsubscribe\""))
    }
}
