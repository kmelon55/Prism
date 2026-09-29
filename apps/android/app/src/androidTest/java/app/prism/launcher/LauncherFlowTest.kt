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
        rule.waitForIdle()
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        // UIAutomation captures the system compositor, which can trail Compose by a few frames.
        android.os.SystemClock.sleep(300)
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

    private fun openSearch() {
        if (rule.onAllNodesWithTag("home-surface").fetchSemanticsNodes().isNotEmpty()) {
            rule.onNodeWithTag("home-search-gesture").performTouchInput {
                swipe(Offset(centerX, height * .8f), Offset(centerX, -220f), 350)
            }
        } else rule.onNodeWithContentDescription(text(R.string.search_apps)).performClick()
        rule.onNodeWithTag("prism-search").assertIsDisplayed()
    }

    private fun openApps() {
        openSearch()
        rule.onNode(hasSetTextAction()).performTextInput(text(R.string.all_apps))
        rule.onNodeWithTag("palette-command-AllApps").performClick()
        rule.onNodeWithTag("alphabet-apps").assertIsDisplayed()
    }

    @Test fun searchPullDownReturnsHomeWithoutDockButtons() {
        home()
        rule.onNodeWithContentDescription(text(R.string.search_apps)).assertDoesNotExist()
        rule.onNodeWithContentDescription(text(R.string.all_apps)).assertDoesNotExist()
        openSearch()
        rule.onNode(hasSetTextAction()).performTextInput("no-app-matches-9371")
        rule.onNodeWithTag("search-results").performTouchInput {
            swipe(Offset(centerX, 30f), Offset(centerX, height * .8f), 400)
        }
        rule.onNodeWithTag("home-surface").assertIsDisplayed()
        rule.onNodeWithTag("prism-search").assertDoesNotExist()
        openSearch()
        rule.onNode(hasSetTextAction()).assertTextContains("")
        home()
    }

    @Test fun favoriteLongPressDragPersistsWithoutLaunching() {
        home()
        val apps = catalog().take(6)
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        val previous = model.state.value.favorites
        val recent = model.state.value.recent
        try {
            rule.runOnIdle {
                model.state.value.favorites.toList().forEach(model::toggleFavorite)
                apps.forEach { model.toggleFavorite(it.id) }
            }
            val first = rule.onNodeWithTag("home-favorite-${apps[0].id}").performScrollTo().fetchSemanticsNode().boundsInRoot
            val third = rule.onNodeWithTag("home-favorite-${apps[2].id}").fetchSemanticsNode().boundsInRoot
            val list = rule.onNodeWithTag("home-list").fetchSemanticsNode().boundsInRoot
            rule.mainClock.autoAdvance = false
            try {
                rule.onNodeWithTag("home-list").performTouchInput {
                    down(Offset(first.center.x - list.left, first.center.y - list.top))
                }
                rule.mainClock.advanceTimeBy(700)
                rule.onNodeWithTag("home-list").performTouchInput {
                    moveTo(Offset(first.center.x - list.left, third.center.y - list.top), 500)
                    up()
                }
            } finally { rule.mainClock.autoAdvance = true }
            rule.waitForIdle()
            org.junit.Assert.assertEquals("Actual order: ${model.state.value.favorites}", apps[0].id, model.state.value.favorites[2])
            org.junit.Assert.assertEquals(recent, model.state.value.recent)
            rule.activityRule.scenario.recreate()
            org.junit.Assert.assertEquals(apps[0].id, ViewModelProvider(rule.activity)[LauncherModel::class.java].state.value.favorites[2])
            rule.onNodeWithTag("add-favorites").performScrollTo().assertIsDisplayed()
            screenshot("minimal-home.png")
        } finally {
            rule.runOnIdle {
                val current = ViewModelProvider(rule.activity)[LauncherModel::class.java]
                current.state.value.favorites.toList().forEach(current::toggleFavorite)
                previous.forEach(current::toggleFavorite)
            }
            home()
        }
    }

    @Test fun draggedFavoriteScrollsPastTheVisibleApps() {
        home()
        val apps = catalog()
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        val previous = model.state.value.favorites
        try {
            rule.runOnIdle {
                model.state.value.favorites.toList().forEach(model::toggleFavorite)
                apps.forEach { model.toggleFavorite(it.id) }
            }
            val id = apps.first().id
            val first = rule.onNodeWithTag("home-favorite-$id").performScrollTo().fetchSemanticsNode().boundsInRoot
            val list = rule.onNodeWithTag("home-list").fetchSemanticsNode().boundsInRoot
            rule.mainClock.autoAdvance = false
            try {
                rule.onNodeWithTag("home-list").performTouchInput {
                    down(Offset(first.center.x - list.left, first.center.y - list.top))
                }
                rule.mainClock.advanceTimeBy(700)
                rule.onNodeWithTag("home-list").performTouchInput { moveTo(Offset(first.center.x - list.left, list.height - 12f), 300) }
                repeat(100) { rule.mainClock.advanceTimeByFrame(); rule.waitForIdle() }
                rule.onNodeWithTag("home-list").performTouchInput { up() }
            } finally { rule.mainClock.autoAdvance = true }
            rule.waitForIdle()
            screenshot("favorite-edge-scroll.png")
            org.junit.Assert.assertTrue("Held item follows the edge scroll: index=${model.state.value.favorites.indexOf(id)}, count=${apps.size}", model.state.value.favorites.indexOf(id) >= apps.size - 2)
            rule.onNodeWithTag("home-surface").assertIsDisplayed()
        } finally {
            rule.runOnIdle {
                model.state.value.favorites.toList().forEach(model::toggleFavorite)
                previous.forEach(model::toggleFavorite)
            }
            home()
        }
    }

    @Test fun themeCustomizationPersistsAndWidgetPickerShowsInstalledProviders() {
        home()
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        val previous = model.state.value
        try {
            openSearch()
            rule.onNode(hasSetTextAction()).performTextInput(text(R.string.settings))
            rule.onNodeWithTag("palette-command-Settings").performClick()
            rule.onNodeWithTag("theme-accent-sage").performClick()
            rule.onNodeWithTag("wallpaper-dim").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { it(.8f) }
            rule.onNodeWithTag("show-clock").performScrollTo().performClick()
            rule.activityRule.scenario.recreate()
            rule.onNodeWithTag("theme-accent-sage").performScrollTo().assertIsSelected()
            val current = ViewModelProvider(rule.activity)[LauncherModel::class.java].state.value
            org.junit.Assert.assertEquals("sage", current.themeAccent)
            org.junit.Assert.assertEquals(.8f, current.wallpaperDim, .01f)
            org.junit.Assert.assertEquals(!previous.showClock, current.showClock)
            screenshot("minimal-theme-settings.png")
            home()
            if (previous.showClock) rule.onNodeWithTag("prism-clock").assertDoesNotExist()
            openSearch()
            rule.onNode(hasSetTextAction()).performTextInput(text(R.string.add_widget))
            rule.onNodeWithTag("palette-command-Widgets").performClick()
            rule.onNodeWithTag("widget-picker").assertIsDisplayed()
            val provider = rule.activity.widgets.manager.getInstalledProvidersForProfile(android.os.Process.myUserHandle())
                .first { it.widgetCategory and android.appwidget.AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN != 0 }
            rule.onNodeWithTag("widget-search").performTextInput(provider.loadLabel(rule.activity.packageManager))
            rule.onNodeWithTag("widget-provider-${provider.provider.flattenToString()}").performScrollTo().assertIsDisplayed()
            screenshot("native-widget-picker.png")
        } finally {
            rule.runOnIdle {
                val current = ViewModelProvider(rule.activity)[LauncherModel::class.java]
                current.setThemeAccent(previous.themeAccent); current.setWallpaperDim(previous.wallpaperDim); current.setShowClock(previous.showClock)
            }
            home()
        }
    }

    @Test fun installedWidgetPagesSwipeAndPersistSelection() {
        home()
        val widgets = rule.activity.widgets
        val previous = widgets.stack.value
        val provider = widgets.manager.getInstalledProvidersForProfile(android.os.Process.myUserHandle())
            .first { it.configure == null && it.widgetCategory and android.appwidget.AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN != 0 }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val created = mutableListOf<Int>()
        try {
            automation.adoptShellPermissionIdentity("android.permission.BIND_APPWIDGET")
            repeat(2) {
                val count = widgets.stack.value.slots.size
                rule.runOnIdle { widgets.add(provider) }
                rule.waitUntil(5_000) { widgets.stack.value.slots.size == count + 1 }
                created += widgets.activeId.value
            }
            automation.dropShellPermissionIdentity()
            rule.onNodeWithTag("widget-pager").performTouchInput { swipeRight(durationMillis = 600) }
            rule.waitUntil(5_000) { widgets.activeId.value == created.first() }
            rule.onNodeWithTag("widget-pager").performTouchInput { swipeLeft(durationMillis = 600) }
            rule.waitUntil(5_000) { widgets.activeId.value == created.last() }
            rule.activityRule.scenario.recreate()
            org.junit.Assert.assertEquals(created.last(), rule.activity.widgets.activeId.value)
            screenshot("widget-pager-home.png")
        } finally {
            automation.dropShellPermissionIdentity()
            rule.runOnIdle {
                val current = rule.activity.widgets
                created.forEach { current.select(it); current.remove() }
                previous.active?.let { current.select(it.id) }
            }
            home()
        }
    }

    @Test fun installedAndroidWidgetBindsAndRendersOnHome() {
        home()
        val widgets = rule.activity.widgets
        val previous = widgets.stack.value
        val provider = widgets.manager.getInstalledProvidersForProfile(android.os.Process.myUserHandle())
            .first { it.configure == null && it.widgetCategory and android.appwidget.AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN != 0 }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        var createdId: Int? = null
        try {
            // Grant only this instrumented call shell identity; normal users receive Android's consent dialog.
            automation.adoptShellPermissionIdentity("android.permission.BIND_APPWIDGET")
            rule.runOnIdle { widgets.add(provider) }
            rule.waitUntil(5_000) { widgets.activeId.value != (previous.active?.id ?: -1) }
            createdId = widgets.activeId.value
            automation.dropShellPermissionIdentity()
            rule.onNodeWithTag("native-home-widget").assertIsDisplayed()
            org.junit.Assert.assertEquals(provider.provider, widgets.manager.getAppWidgetInfo(createdId!!).provider)
            screenshot("native-widget-home.png")
            rule.activityRule.scenario.recreate()
            rule.onNodeWithTag("native-home-widget").assertIsDisplayed()
            org.junit.Assert.assertEquals(createdId, rule.activity.widgets.activeId.value)
        } finally {
            automation.dropShellPermissionIdentity()
            rule.runOnIdle {
                val current = rule.activity.widgets
                createdId?.let { current.select(it); current.remove() }
                previous.active?.let { current.select(it.id) }
            }
            home()
        }
    }

    @Test fun favoriteAndKoreanAliasSurviveActivityRecreation() {
        home()
        val app = catalog().first()
        val label = app.label
        openApps()
        openSearch()
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
        openSearch()
        rule.onNode(hasSetTextAction()).performTextInput("no-app-matches-this-query-9371")
        rule.onNodeWithText(text(R.string.empty_search)).assertIsDisplayed()
        home()
        rule.onNodeWithTag("home-surface").assertIsDisplayed()
        openApps()
        openSearch()
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
        rule.onNodeWithTag("alphabet-preview").assertTextEquals(alphabetLabel(sections[first], true))
        rule.onAllNodes(hasSetTextAction()).assertCountEquals(0)
        screenshot("alphabet-drag.png")
        // Continue the SAME finger after the home content has been replaced.
        rail.performTouchInput { moveTo(Offset(centerX, height * (last + .5f) / sections.size)) }
        rule.waitForIdle()
        rule.onNodeWithTag("alphabet-preview").assertTextEquals(alphabetLabel(sections[last], true))
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

    @Test fun bottomSwipeOpensTopSearchAndKeepsUnmatchedQuery() {
        home()
        rule.onNodeWithTag("home-search-gesture").performTouchInput {
            swipe(Offset(centerX, height * .9f), Offset(centerX, -height.toFloat()), 350)
        }
        rule.onNodeWithTag("prism-search").assertIsDisplayed()
        screenshot("prism-search.png")
        val input = rule.onNode(hasSetTextAction()).fetchSemanticsNode().boundsInRoot
        val back = rule.onNodeWithContentDescription(text(R.string.back)).fetchSemanticsNode().boundsInRoot
        org.junit.Assert.assertTrue("Search stays beside the back arrow", input.left >= back.right)
        org.junit.Assert.assertTrue("Search and back share the top row", back.center.y in input.top..input.bottom)
        val query = "no-app-matches-this-query-9371"
        rule.onNode(hasSetTextAction()).performTextInput(query)
        rule.onNode(hasSetTextAction()).performImeAction()
        rule.onNodeWithTag("prism-search").assertIsDisplayed()
        rule.onNodeWithText(text(R.string.empty_search)).assertIsDisplayed()
        rule.activityRule.scenario.recreate()
        rule.onNodeWithTag("prism-search").assertIsDisplayed()
        rule.onNode(hasSetTextAction()).assertTextContains(query)
        rule.onNodeWithContentDescription(text(R.string.clear)).performClick()
        rule.onNode(hasSetTextAction()).assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")))
        rule.onNodeWithContentDescription(text(R.string.back)).performClick()
        rule.onNodeWithTag("home-surface").assertIsDisplayed()
    }

    @Test fun paletteCommandOpensFavoriteEditing() {
        home()
        openSearch()
        rule.onNode(hasSetTextAction()).performTextInput("즐겨찾기 편집")
        rule.onNode(hasText(text(R.string.edit_home)) and !hasSetTextAction()).performClick()
        // System IME dismissal can finish after Compose has become idle.
        rule.waitUntil(5_000) { runCatching { rule.onNodeWithTag("home-surface").assertIsDisplayed() }.isSuccess }
        rule.onNodeWithTag("home-surface").assertIsDisplayed()
        rule.onNodeWithText(text(R.string.done)).assertIsDisplayed()
        home()
    }

    @Test fun choosingFavoritesAddsAppsWithoutLaunchingAndPersists() {
        home()
        val apps = catalog().take(6)
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        val previous = model.state.value.favorites
        val previousRecent = model.state.value.recent
        val keepForReview = InstrumentationRegistry.getArguments().getString("keepReviewFavorites") == "true"
        var completed = false
        try {
            rule.runOnIdle { model.state.value.favorites.toList().forEach(model::toggleFavorite) }
            rule.onNodeWithTag("add-favorites").performScrollTo().performClick()
            rule.onNodeWithTag("favorites-picker").assertIsDisplayed()
            apps.forEach { app ->
                rule.onNodeWithTag("favorite-picker-${app.id}").performScrollTo().performClick()
                rule.onNodeWithTag("favorite-toggle-${app.id}").assertIsOn()
                rule.onNodeWithTag("favorites-picker").assertIsDisplayed()
            }
            org.junit.Assert.assertEquals(previousRecent, model.state.value.recent)
            val first = apps.first()
            rule.onNodeWithTag("favorite-toggle-${first.id}").performScrollTo().performClick()
            rule.onNodeWithTag("favorite-toggle-${first.id}").assertIsOff()
            rule.onNodeWithTag("favorite-picker-${first.id}").performClick()
            rule.activityRule.scenario.recreate()
            rule.onNodeWithTag("favorite-toggle-${first.id}").performScrollTo().assertIsOn()
            screenshot("glass-favorites-picker.png")
            rule.onNodeWithTag("favorites-done").performClick()
            rule.onNodeWithTag("home-surface").assertIsDisplayed()
            rule.onNode(hasText(first.label) and hasAnyAncestor(hasTestTag("home-surface"))).assertIsDisplayed()
            val saved = org.json.JSONArray(rule.activity.getSharedPreferences("launcher", android.content.Context.MODE_PRIVATE)
                .getString("favorites", "[]"))
            org.junit.Assert.assertEquals(apps.map { it.id }.toSet(), (0 until saved.length()).map { saved.getString(it) }.toSet())
            screenshot("glass-home-favorites.png")
            // The command provides the same picker even after the empty-home prompt is gone.
            openSearch()
            rule.onNode(hasSetTextAction()).performTextInput(text(R.string.add_favorites))
            rule.onNodeWithTag("palette-command-ChooseFavorites").performClick()
            rule.onNodeWithTag("favorites-picker").assertIsDisplayed()
            completed = true
        } finally {
            rule.runOnIdle {
                val current = ViewModelProvider(rule.activity)[LauncherModel::class.java]
                val target = if (keepForReview && completed) (previous + apps.map { it.id }).distinct() else previous
                current.state.value.favorites.toList().forEach(current::toggleFavorite)
                target.forEach(current::toggleFavorite)
            }
            home()
        }
    }

    @Test fun returningToFavoritesSlidesHomeDownWhileKeepingTheRail() {
        home()
        catalog()
        openApps()
        rule.onNodeWithTag("alphabet-apps").assertIsDisplayed()
        rule.mainClock.autoAdvance = false
        try {
            rule.onNodeWithTag("alphabet-letter-★").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick) { it() }
            rule.mainClock.advanceTimeBy(80)
            val early = rule.onNodeWithTag("home-surface").fetchSemanticsNode().boundsInRoot.bottom
            rule.onNodeWithTag("alphabet-rail").assertExists()
            rule.mainClock.advanceTimeBy(450)
            val settled = rule.onNodeWithTag("home-surface").fetchSemanticsNode().boundsInRoot.bottom
            org.junit.Assert.assertTrue("Home moves down into place instead of replacing the screen instantly", early < settled - 1f)
            rule.onNodeWithTag("alphabet-apps").assertDoesNotExist()
        } finally { rule.mainClock.autoAdvance = true }
    }

    @Test fun surfaceModesPersistIndependentlyOfIconAndWallpaperPreferences() {
        org.junit.Assume.assumeTrue(android.os.Build.VERSION.SDK_INT >= 33)
        home()
        catalog()
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        val previous = model.state.value
        try {
            openSearch()
            rule.onNode(hasSetTextAction()).performTextInput(text(R.string.settings))
            rule.onNodeWithTag("palette-command-Settings").performClick()
            for (appearance in listOf(PrismAppearance.Liquid, PrismAppearance.Matte, PrismAppearance.Flat, PrismAppearance.Liquid)) {
                rule.onNodeWithTag("appearance-${appearance.key}").performScrollTo().performClick()
                rule.activityRule.scenario.recreate()
                rule.onNodeWithTag("appearance-${appearance.key}").performScrollTo().assertIsSelected()
                val current = ViewModelProvider(rule.activity)[LauncherModel::class.java].state.value
                org.junit.Assert.assertEquals(appearance, PrismAppearance.resolve(current.prismEffects, current.prismMaterial))
                org.junit.Assert.assertEquals(previous.prismIcons, current.prismIcons)
                org.junit.Assert.assertEquals(previous.wallpaperDim, current.wallpaperDim)
            }
            screenshot("liquid-mode-settings.png")
            home()
            screenshot("liquid-mode-home.png")
        } finally {
            rule.runOnIdle {
                val current = ViewModelProvider(rule.activity)[LauncherModel::class.java]
                current.setAppearance(if (previous.prismMaterial == "liquid") PrismAppearance.Liquid else PrismAppearance.Matte)
                current.setPrismEffects(previous.prismEffects)
            }
            home()
        }
    }

    @Test fun prismThemePersistsAndRendersLauncherSurfaces() {
        home()
        val apps = catalog().take(5)
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        val previous = model.state.value
        var folderId: String? = null
        try {
            rule.runOnIdle {
                model.setAppearance(PrismAppearance.Matte)
                model.setPrismIcons(true)
                apps.filterNot { it.id in model.state.value.favorites }.forEach { model.toggleFavorite(it.id) }
                model.saveFolder(null, "Prism preview", apps.take(3).map { it.id })
                folderId = model.state.value.folders.last().id
            }
            rule.waitForIdle()
            screenshot("prism-theme-home.png")
            rule.onNodeWithTag("home-list").performScrollToKey("folder:$folderId")
            rule.onNodeWithTag("folder-$folderId").performClick()
            // The dialog window is attached separately from the home composition.
            rule.waitUntil(5_000) { runCatching { rule.onNodeWithTag("folder-popup").assertIsDisplayed() }.isSuccess }
            rule.onNodeWithTag("folder-popup").assertIsDisplayed()
            screenshot("prism-theme-folder.png")
            home()
            openSearch()
            rule.onNode(hasSetTextAction()).assertIsDisplayed()
            screenshot("prism-theme-search.png")
            rule.onNode(hasSetTextAction()).performTextInput(text(R.string.settings))
            rule.onNodeWithTag("palette-command-Settings").performClick()
            rule.onNodeWithTag("appearance-flat").performScrollTo().performClick()
            rule.onNodeWithTag("icons-original").performScrollTo().performClick()
            rule.activityRule.scenario.recreate()
            rule.onNodeWithTag("appearance-flat").performScrollTo().assertIsSelected()
            rule.onNodeWithTag("icons-original").performScrollTo().assertIsSelected()
            val preferences = rule.activity.getSharedPreferences("launcher", android.content.Context.MODE_PRIVATE)
            org.junit.Assert.assertFalse(preferences.getBoolean("prismEffects", true))
            org.junit.Assert.assertFalse(preferences.getBoolean("prismIcons", true))
            screenshot("prism-theme-settings-flat.png")
            rule.onNodeWithTag("appearance-matte").performScrollTo().performClick()
            rule.onNodeWithTag("icons-themed").performScrollTo().performClick()
            screenshot("prism-theme-settings.png")
        } finally {
            rule.runOnIdle {
                val current = ViewModelProvider(rule.activity)[LauncherModel::class.java]
                current.setAppearance(if (previous.prismMaterial == "liquid") PrismAppearance.Liquid else PrismAppearance.Matte)
                current.setPrismEffects(previous.prismEffects)
                current.setPrismIcons(previous.prismIcons)
                current.state.value.favorites.filterNot { it in previous.favorites }.forEach { current.toggleFavorite(it) }
                folderId?.let(current::removeFolder)
            }
            home()
        }
    }

    @Test fun widgetStackMigratesPersistsAndPreservesSelectionOnCancellation() {
        home()
        val preferences = rule.activity.getSharedPreferences("widgets", android.content.Context.MODE_PRIVATE)
        val previous = preferences.all.toMap()
        try {
            preferences.edit().clear().putInt("active", 9371).putInt("height", 200).commit()
            rule.activityRule.scenario.recreate()
            org.junit.Assert.assertEquals(WidgetSlot(9371, 200), rule.activity.widgets.stack.value.active)
            rule.runOnIdle { rule.activity.widgets.resize(40) }
            org.junit.Assert.assertTrue(preferences.contains("stack"))
            preferences.edit().putString("stack", "[{\"id\":9371,\"height\":240},{\"id\":9372,\"height\":300}]").commit()
            rule.activityRule.scenario.recreate()
            rule.runOnIdle { rule.activity.widgets.step(1) }
            org.junit.Assert.assertEquals(WidgetSlot(9372, 300), rule.activity.widgets.stack.value.active)
            rule.activityRule.scenario.recreate()
            org.junit.Assert.assertEquals(9372, rule.activity.widgets.activeId.value)
            rule.runOnIdle {
                val widgets = rule.activity.widgets
                val pending = widgets.host.allocateAppWidgetId()
                preferences.edit().putInt("pending", pending).commit()
                widgets.configurationResult(android.app.Activity.RESULT_CANCELED)
                org.junit.Assert.assertFalse(widgets.host.appWidgetIds.contains(pending))
                org.junit.Assert.assertEquals(listOf(WidgetSlot(9371, 240), WidgetSlot(9372, 300)), widgets.stack.value.slots)
                org.junit.Assert.assertEquals(9372, widgets.activeId.value)
            }
        } finally {
            val editor = preferences.edit().clear()
            previous.forEach { (key, value) ->
                when (value) {
                    is String -> editor.putString(key, value)
                    is Int -> editor.putInt(key, value)
                    is Long -> editor.putLong(key, value)
                    is Boolean -> editor.putBoolean(key, value)
                    is Float -> editor.putFloat(key, value)
                    is Set<*> -> editor.putStringSet(key, value.filterIsInstance<String>().toSet())
                }
            }
            editor.commit()
            rule.activityRule.scenario.recreate()
            home()
        }
    }

    @Test fun appSwipeOpensActionsWithoutLaunchingApp() {
        home()
        val app = catalog().first()
        openSearch()
        rule.onNode(hasSetTextAction()).performTextInput(app.label)
        rule.onNode(hasText(app.label) and !hasSetTextAction()).performTouchInput { swipeRight() }
        rule.onNodeWithText(text(R.string.app_shortcuts)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.edit_alias)).assertIsDisplayed()
        home()
    }

    @Test fun folderCreationEditingAndDeletionPersistWithoutChangingFavorites() {
        home()
        val app = catalog().first()
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        val originalFavorites = model.state.value.favorites
        var createdId: String? = null
        try {
            openSearch()
            rule.onNode(hasSetTextAction()).performTextInput(text(R.string.edit_home))
            rule.onNodeWithTag("palette-command-EditHome").performClick()
            rule.onNodeWithTag("home-list").performScrollToKey("create-folder")
            rule.onNodeWithTag("create-folder").performClick()
            rule.onNodeWithTag("folder-name").performTextInput("Test folder 9371")
            rule.onNodeWithTag("folder-app-search").performTextInput(app.label)
            rule.onNode(hasText(app.label) and hasAnyAncestor(hasTestTag("folder-app-picker"))).performClick()
            rule.onNodeWithText(text(R.string.save)).performClick()
            rule.runOnIdle { createdId = model.state.value.folders.single { it.name == "Test folder 9371" }.id }
            home()
            rule.activityRule.scenario.recreate()
            rule.onNodeWithTag("home-list").performScrollToKey("folder:$createdId")
            rule.onNodeWithTag("folder-$createdId").performClick()
            rule.onNodeWithTag("folder-popup").assertIsDisplayed()
            rule.onNode(hasText(app.label) and hasAnyAncestor(hasTestTag("folder-popup"))).assertIsDisplayed()
            rule.onNodeWithContentDescription(text(R.string.edit_folder)).performClick()
            rule.onNodeWithTag("folder-name").performTextReplacement("Renamed folder 9371")
            rule.onNodeWithText(text(R.string.save)).performClick()
            val json = org.json.JSONArray(rule.activity.getSharedPreferences("launcher", android.content.Context.MODE_PRIVATE)
                .getString("folders", "[]"))
            val saved = (0 until json.length()).map { json.getJSONObject(it) }.single { it.getString("id") == createdId }
            org.junit.Assert.assertEquals("Renamed folder 9371", saved.getString("name"))
            org.junit.Assert.assertEquals(app.id, saved.getJSONArray("apps").getString(0))
            rule.onNodeWithTag("home-list").performScrollToKey("folder:$createdId")
            rule.onNodeWithTag("folder-$createdId").performTouchInput { longClick() }
            rule.onNodeWithText(text(R.string.delete_folder)).performClick()
            rule.onNodeWithTag("confirm-delete-folder").performClick()
            rule.onNodeWithTag("folder-$createdId").assertDoesNotExist()
            org.junit.Assert.assertEquals(originalFavorites,
                ViewModelProvider(rule.activity)[LauncherModel::class.java].state.value.favorites)
        } finally {
            rule.runOnIdle { createdId?.let { ViewModelProvider(rule.activity)[LauncherModel::class.java].removeFolder(it) } }
            home()
        }
    }

    @Test fun indexPreferencesPersistAndUpdateTheirControls() {
        home()
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        val previousAll = model.state.value.showAllIndexLetters
        val previousSyllables = model.state.value.koreanIndexSyllables
        try {
            rule.runOnIdle { model.setShowAllIndexLetters(false); model.setKoreanIndexSyllables(true) }
            openSearch()
            rule.onNode(hasSetTextAction()).performTextInput(text(R.string.settings))
            rule.onNodeWithTag("palette-command-Settings").performClick()
            rule.onNodeWithContentDescription(text(R.string.alphabet_show_all)).performClick()
            rule.onNodeWithText("ㄱ · ㄴ · ㄷ").performScrollTo().performClick()
            rule.activityRule.scenario.recreate()
            rule.onNodeWithContentDescription(text(R.string.alphabet_show_all)).assertIsOn()
            rule.onNodeWithText("ㄱ · ㄴ · ㄷ").assertIsSelected()
            val preferences = rule.activity.getSharedPreferences("launcher", android.content.Context.MODE_PRIVATE)
            org.junit.Assert.assertTrue(preferences.getBoolean("showAllIndexLetters", false))
            org.junit.Assert.assertFalse(preferences.getBoolean("koreanIndexSyllables", true))
            screenshot("index-settings.png")
            home()
            val sections = alphabetSections(catalog().map { it.label }, showAll = true)
            val index = sections.indexOf("ㄱ")
            if (index >= 0) {
                val rail = rule.onNodeWithTag("alphabet-rail")
                rail.performTouchInput { down(Offset(centerX, height * (index + .5f) / sections.size)) }
                rule.waitForIdle()
                rule.onNodeWithTag("alphabet-preview").assertTextEquals("ㄱ")
                screenshot("full-index-initials.png")
                rail.performTouchInput { up() }
            }
        } finally {
            rule.runOnIdle { model.setShowAllIndexLetters(previousAll); model.setKoreanIndexSyllables(previousSyllables) }
            home()
        }
    }

    @Test fun englishGroupingAndSelectedOnlyPersistAndFilterTheActualCatalog() {
        home()
        val apps = catalog()
        val model = ViewModelProvider(rule.activity)[LauncherModel::class.java]
        val previous = model.state.value
        try {
            rule.runOnIdle { model.setShowAllIndexLetters(true); model.setShowKoreanIndex(true); model.setSelectedIndexOnly(false) }
            openSearch()
            rule.onNode(hasSetTextAction()).performTextInput(text(R.string.settings))
            rule.onNodeWithTag("palette-command-Settings").performClick()
            rule.onNodeWithText(text(R.string.korean_index_english)).performScrollTo().performClick()
            rule.onNodeWithText(text(R.string.index_browse_selected)).performScrollTo().performClick()
            rule.activityRule.scenario.recreate()
            rule.onNodeWithText(text(R.string.korean_index_english)).performScrollTo().assertIsSelected()
            rule.onNodeWithText(text(R.string.index_browse_selected)).performScrollTo().assertIsSelected()
            screenshot("index-options.png")
            val preferences = rule.activity.getSharedPreferences("launcher", android.content.Context.MODE_PRIVATE)
            org.junit.Assert.assertFalse(preferences.getBoolean("showKoreanIndex", true))
            org.junit.Assert.assertTrue(preferences.getBoolean("selectedIndexOnly", false))
            home()
            rule.onNodeWithTag("alphabet-letter-ㄱ").assertDoesNotExist()
            val translated = apps.first {
                AppSearch.section(it.label) in "ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎ".map(Char::toString) &&
                    AppSearch.section(it.englishLabel) in ('A'..'Z').map(Char::toString)
            }
            val letter = AppIndex.section(translated.label, translated.englishLabel, false)
            val sections = listOf("★") + AppIndex.order(false)
            val rail = rule.onNodeWithTag("alphabet-rail")
            rail.performTouchInput { down(Offset(centerX, height * (sections.indexOf(letter) + .5f) / sections.size)) }
            rule.waitForIdle()
            rule.onNodeWithText(translated.label).assertIsDisplayed()
            apps.filter { AppIndex.section(it.label, it.englishLabel, false) != letter }.forEach {
                rule.onNodeWithText(it.label).assertDoesNotExist()
            }
            screenshot("english-selected-group.png")
            val empty = AppIndex.order(false).first { section -> apps.none { AppIndex.section(it.label, it.englishLabel, false) == section } }
            rail.performTouchInput { moveTo(Offset(centerX, height * (sections.indexOf(empty) + .5f) / sections.size)) }
            rule.waitForIdle()
            rule.onNodeWithText(text(R.string.empty_index_section)).assertIsDisplayed()
            rule.onNodeWithText(translated.label).assertDoesNotExist()
            rail.performTouchInput { up() }
            rule.waitForIdle()
            rule.onNodeWithText(text(R.string.empty_index_section)).assertIsDisplayed()
        } finally {
            rule.runOnIdle {
                model.setShowAllIndexLetters(previous.showAllIndexLetters)
                model.setShowKoreanIndex(previous.showKoreanIndex)
                model.setSelectedIndexOnly(previous.selectedIndexOnly)
            }
            home()
        }
    }

    @Test fun smallIndexMovesScrollContinuouslyWithinTheSameLetter() {
        home()
        val apps = catalog()
        val sections = alphabetSections(apps.map { it.label })
        val groups = apps.groupBy { AppSearch.section(it.label) }.toList()
        val middle = (groups.size / 2).coerceAtMost(groups.lastIndex - 1)
        val (letter, group) = groups[middle]
        val index = sections.indexOf(letter)
        val rail = rule.onNodeWithTag("alphabet-rail")
        rail.performTouchInput { down(Offset(centerX, height * (index + .5f) / sections.size)) }
        rule.waitForIdle()
        val target = rule.onNodeWithText(group.first().label)
        val before = target.fetchSemanticsNode().boundsInRoot.center.y
        rail.performTouchInput { moveTo(Offset(centerX, height * (index + .75f) / sections.size)) }
        rule.waitForIdle()
        rail.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, letter))
        val after = target.fetchSemanticsNode().boundsInRoot.center.y
        org.junit.Assert.assertTrue("List moves between letter changes", kotlin.math.abs(after - before) > 1f)
        rail.performTouchInput { up() }
        rule.waitForIdle()
        org.junit.Assert.assertEquals(after, target.fetchSemanticsNode().boundsInRoot.center.y, 2f)
    }

    @Test fun fullIndexKeepsEveryVerticalSlotWhileDragging() {
        home()
        catalog()
        val sections = listOf("★") + AppSearch.sectionOrder
        fun positions() = sections.map { section ->
            val node = rule.onNodeWithTag("alphabet-letter-$section")
            node.assertIsDisplayed()
            node.fetchSemanticsNode().boundsInRoot.center.y
        }
        val before = positions()
        val rail = rule.onNodeWithTag("alphabet-rail")
        rail.performTouchInput { down(Offset(centerX, height * .30f)) }
        rule.waitForIdle()
        org.junit.Assert.assertEquals(before, positions())
        screenshot("fixed-index-upper.png")
        rail.performTouchInput { moveTo(Offset(centerX - width, height * .68f)) }
        rule.waitForIdle()
        org.junit.Assert.assertEquals(before, positions())
        screenshot("fixed-index-lower.png")
        rail.performTouchInput { up() }
        rule.waitForIdle()
        org.junit.Assert.assertEquals(before, positions())
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

    @Test fun bothEdgesPlaceTheChosenGroupAboveTheFingerAndKeepPositionOnRelease() {
        val apps = catalog()
        val sections = alphabetSections(apps.map { it.label })
        val app = apps[apps.size / 2]
        val letter = AppSearch.section(app.label)
        val firstInGroup = apps.first { AppSearch.section(it.label) == letter }
        val index = sections.indexOf(letter)
        for (tag in listOf("alphabet-rail", "alphabet-rail-left")) {
            home()
            val rail = rule.onNodeWithTag(tag)
            val railBounds = rail.fetchSemanticsNode().boundsInRoot
            val touchY = railBounds.height * (index + .5f) / sections.size
            rail.performTouchInput { down(Offset(centerX, touchY)) }
            rule.waitForIdle()
            val target = rule.onNode(hasText(firstInGroup.label) and !hasSetTextAction())
            target.assertIsDisplayed()
            val before = target.fetchSemanticsNode().boundsInRoot.center.y
            val finger = railBounds.top + touchY
            val density = rule.activity.resources.displayMetrics.density
            org.junit.Assert.assertTrue("Selected group starts above the thumb: $before vs $finger",
                before < finger && finger - before < 150f * density)
            rail.performTouchInput { up() }
            rule.waitForIdle()
            val after = target.fetchSemanticsNode().boundsInRoot.center.y
            org.junit.Assert.assertEquals("Release must not jump the app list", before, after, 2f)
            screenshot(if (tag.endsWith("left")) "browse-left.png" else "browse-right.png")
            rule.onAllNodes(hasSetTextAction()).assertCountEquals(0)
        }
    }

}
