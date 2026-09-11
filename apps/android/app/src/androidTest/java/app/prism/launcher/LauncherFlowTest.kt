package app.prism.launcher

import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.geometry.Offset
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import android.graphics.Bitmap
import java.io.File
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LauncherFlowTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()
    private fun text(id: Int) = rule.activity.getString(id)
    private fun catalog(): List<LauncherApp> {
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        rule.waitUntil(10_000) { !model.state.value.loading && model.state.value.apps.isNotEmpty() }
        return model.state.value.apps
    }
    private fun screenshot(name: String) {
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(rule.activity.getExternalFilesDir(null), name).outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        bitmap.recycle()
    }

    private fun home() {
        rule.activityRule.scenario.onActivity { activity ->
            activity.startActivity(Intent(activity, MainActivity::class.java)
                .setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        rule.waitForIdle()
    }

    @Test fun favoriteAndKoreanAliasSurviveActivityRecreation() {
        home()
        val app = catalog().first()
        val label = app.label
        rule.onNodeWithContentDescription(text(R.string.all_apps)).performClick()
        rule.onNodeWithContentDescription(text(R.string.search_apps)).performClick()
        rule.onNode(hasSetTextAction()).performTextInput(label)
        rule.onNode(hasText(label) and !hasSetTextAction()).performTouchInput { longClick() }
        // Idempotent on an emulator used for manual QA as well.
        if (rule.onAllNodesWithText(text(R.string.add_favorite)).fetchSemanticsNodes().isNotEmpty()) {
            rule.onNodeWithText(text(R.string.add_favorite)).performClick()
        } else {
            rule.onNodeWithText(text(R.string.edit_alias)).performClick()
            rule.onNodeWithText(text(R.string.cancel)).performClick()
        }
        rule.onNode(hasText(label) and !hasSetTextAction()).performTouchInput { longClick() }
        rule.onNodeWithText(text(R.string.edit_alias)).performClick()
        rule.onNode(hasSetTextAction() and hasText(text(R.string.alias))).performTextReplacement("카카오톡")
        rule.onNodeWithText(text(R.string.save)).performClick()
        rule.onNode(hasSetTextAction()).performTextReplacement("ㅋㅌ")
        rule.onNodeWithText(label).assertIsDisplayed()
        rule.activityRule.scenario.recreate()
        rule.onNodeWithText(label).assertIsDisplayed()
        rule.onNode(hasSetTextAction()).assertTextContains("ㅋㅌ")
        rule.onNodeWithContentDescription(text(R.string.back)).performClick()
        rule.onNodeWithText(label).assertIsDisplayed()
    }

    @Test fun homeIntentResetsSearchAndQuery() {
        home()
        rule.onNodeWithContentDescription(text(R.string.search_apps)).performClick()
        rule.onNode(hasSetTextAction()).performTextInput("no-app-matches-this-query-9371")
        rule.onNodeWithText(text(R.string.empty_search)).assertIsDisplayed()
        home()
        rule.onNodeWithContentDescription(text(R.string.search_apps)).assertIsDisplayed()
        rule.onNodeWithContentDescription(text(R.string.all_apps)).performClick()
        rule.onNodeWithContentDescription(text(R.string.search_apps)).performClick()
        rule.onNode(hasSetTextAction()).assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")))
    }
    @Test fun edgeDragContinuesAcrossHomeTransitionWithoutOpeningKeyboard() {
        home()
        val labels = catalog().map { it.label }
        val sections = alphabetSections(labels)
        val first = sections.indexOf(AppSearch.section(labels.first())).coerceAtLeast(1)
        val last = sections.lastIndex
        val rail = rule.onNodeWithTag("alphabet-rail")
        rail.performTouchInput { down(Offset(centerX, height * (first + .5f) / sections.size)) }
        rule.waitForIdle()
        rule.onNodeWithTag("alphabet-apps").assertIsDisplayed()
        rule.onNodeWithTag("alphabet-preview").assertTextEquals(sections[first])
        rule.onAllNodes(hasSetTextAction()).assertCountEquals(0)
        screenshot("alphabet-drag.png")
        // Continue the SAME finger after the home content has been replaced.
        rail.performTouchInput { moveTo(Offset(centerX, height * (last + .5f) / sections.size)) }
        rule.waitForIdle()
        rule.onNodeWithTag("alphabet-preview").assertTextEquals(sections[last])
        rail.performTouchInput { moveTo(Offset(centerX, height * (first + .5f) / sections.size)); up() }
        rule.waitForIdle()
        rule.onNodeWithTag("alphabet-preview").assertDoesNotExist()
        rail.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, sections[first]))
        rule.onNodeWithTag("alphabet-apps").assertIsDisplayed()
        rail.performTouchInput { click(Offset(centerX, height * .5f / sections.size)) }
        rule.onNodeWithTag("home-surface").assertIsDisplayed()
    }

    @Test fun swipeUpOnEmptyHomeOpensSearch() {
        home()
        rule.onNodeWithTag("home-surface").performTouchInput {
            swipe(Offset(width * .4f, height * .85f), Offset(width * .4f, height * .60f), 350)
        }
        rule.onNode(hasSetTextAction()).assertIsDisplayed()
    }

    @Test fun waveTracksThumbPullAndCollapsesAfterRelease() {
        home()
        catalog()
        val rail = rule.onNodeWithTag("alphabet-rail")
        val railBounds = rail.fetchSemanticsNode().boundsInRoot
        rail.performTouchInput { down(Offset(centerX, height * .52f)) }
        rule.waitForIdle()
        val first = rule.onNodeWithTag("alphabet-preview").fetchSemanticsNode().boundsInRoot
        screenshot("wave-middle.png")
        rail.performTouchInput { moveTo(Offset(centerX - width * 1.5f, height * .52f)) }
        rule.waitForIdle()
        val pulled = rule.onNodeWithTag("alphabet-preview").fetchSemanticsNode().boundsInRoot
        org.junit.Assert.assertTrue("Wave follows the thumb horizontally", pulled.center.x < first.center.x - 30f)
        val fingerX = railBounds.left + railBounds.width / 2f - railBounds.width * 1.5f
        org.junit.Assert.assertTrue("Selected glyph clears the thumb", pulled.right < fingerX - 40f)
        screenshot("wave-pulled.png")
        rail.performTouchInput { up() }
        rule.waitForIdle()
        rule.onNodeWithTag("alphabet-preview").assertDoesNotExist()
        rule.onNodeWithTag("alphabet-apps").assertIsDisplayed()
        screenshot("wave-released.png")
    }

}
