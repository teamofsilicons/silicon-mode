package ai.tos.mode

import ai.tos.mode.auth.CallbackParser
import ai.tos.mode.auth.CallbackResult
import ai.tos.mode.data.CellClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthTest {
    @Test
    fun parsesTokenFragment() {
        val r = CallbackParser.parse("access_token=eyJ.a.b&refresh_token=csr_x-y_z&expires_at=1764200000&token_type=Bearer", null)
        assertEquals(CallbackResult.Tokens("eyJ.a.b", "csr_x-y_z", 1764200000L), r)
    }

    @Test
    fun keepsLiteralPlusAndDecodesPercent() {
        val r = CallbackParser.parse("#access_token=a+b&refresh_token=csr%2Fq&expires_at=10", null) as CallbackResult.Tokens
        assertEquals("a+b", r.accessToken)
        assertEquals("csr/q", r.refreshToken)
    }

    @Test
    fun deniedComesFromQueryOrFragment() {
        assertEquals(CallbackResult.Denied("access_denied"), CallbackParser.parse(null, "error=access_denied"))
        assertEquals(CallbackResult.Denied("server_error"), CallbackParser.parse("error=server_error", null))
    }

    @Test
    fun missingTokensAreMalformed() {
        assertEquals(CallbackResult.Malformed, CallbackParser.parse("access_token=a", null))
        assertEquals(CallbackResult.Malformed, CallbackParser.parse("", ""))
    }

    @Test
    fun expiresInFallsBackToNowPlus() {
        val r = CallbackParser.parse("access_token=a&refresh_token=b&expires_in=1800", null) as CallbackResult.Tokens
        val now = System.currentTimeMillis() / 1000
        assertTrue(r.expiresAt in (now + 1790)..(now + 1810))
    }

    @Test
    fun refreshIdempotencyKeyIsSha256Hex() {
        // sha256("abc"), the FIPS 180-2 test vector; same derivation as the JS and Rust clients.
        assertEquals(
            "refresh:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            CellClient.refreshIdempotencyKey("abc"),
        )
    }
}
