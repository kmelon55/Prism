package app.prism.launcher

import android.content.Intent
import android.content.pm.LauncherApps
import android.os.Process
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LauncherFlowTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()
    private fun text(id: Int) = rule.activity.getString(id)

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
        val app = rule.activity.getSystemService(LauncherApps::class.java)
            .getActivityList(null, Process.myUserHandle()).first { it.componentName.packageName != rule.activity.packageName }
        val label = app.label.toString()
        rule.onNodeWithContentDescription(text(R.string.all_apps)).performClick()
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
        rule.onNodeWithText(text(R.string.search_apps)).performClick()
        rule.onNode(hasSetTextAction()).performTextInput("no-app-matches-this-query-9371")
        rule.onNodeWithText(text(R.string.empty_search)).assertIsDisplayed()
        home()
        rule.onNodeWithText(text(R.string.search_apps)).assertIsDisplayed()
        rule.onNodeWithContentDescription(text(R.string.all_apps)).performClick()
        rule.onNode(hasSetTextAction()).assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")))
    }
}
