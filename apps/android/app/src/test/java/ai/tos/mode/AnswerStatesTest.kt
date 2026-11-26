package ai.tos.mode

import ai.tos.mode.data.Answer
import ai.tos.mode.data.AnswerState
import ai.tos.mode.data.AnswerStates
import ai.tos.mode.data.Question
import ai.tos.mode.data.QuestionOption
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AnswerStatesTest {
    private val phone = "0f9a1c2e-1111-4222-8333-944455556666"
    private val question = Question(
        id = "q1",
        deviceId = "mac",
        title = "Run tests?",
        options = listOf(QuestionOption("allow_once", "Allow once", "allow"), QuestionOption("deny", "Deny", "deny")),
    )

    private fun answer(by: String?, from: String = "android", option: String? = "allow_once", text: String? = null) =
        Answer(id = "a1", questionId = "q1", deviceId = "mac", optionId = option, text = text, answeredFrom = from, answeredBy = by)

    @Test
    fun thisPhonesOwnAnswerIsSentNotElsewhere() {
        // A lost RPC response, then the row (realtime or `already_answered`): it is ours.
        assertEquals(AnswerState.Sent("Allow once"), AnswerStates.settled(answer(by = phone), question, phone))
        // answered_by may come back in another case.
        assertEquals(AnswerState.Sent("Allow once"), AnswerStates.settled(answer(by = phone.uppercase()), question, phone))
        assertEquals(AnswerState.Sent("ship it"), AnswerStates.settled(answer(by = phone, option = null, text = " ship it "), question, phone))
    }

    @Test
    fun someoneElsesAnswerSaysWhere() {
        assertEquals(AnswerState.Elsewhere("web"), AnswerStates.settled(answer(by = "another", from = "web"), question, phone))
        assertEquals(AnswerState.Elsewhere("iphone"), AnswerStates.settled(answer(by = null, from = "iphone"), question, phone))
        // Not registered yet: nothing is "mine".
        assertFalse(AnswerStates.isMine(answer(by = phone), null))
        assertTrue(AnswerStates.isMine(answer(by = phone), phone))
    }

    @Test
    fun labelsPreferTheOptionLabel() {
        assertEquals("Deny", AnswerStates.label(question, "deny", null))
        assertEquals("gone_option", AnswerStates.label(question, "gone_option", null))
        assertEquals("yes", AnswerStates.label(null, null, "yes "))
        assertEquals("", AnswerStates.label(question, null, null))
    }
}
