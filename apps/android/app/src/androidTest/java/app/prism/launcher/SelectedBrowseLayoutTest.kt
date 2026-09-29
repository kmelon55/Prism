package app.prism.launcher

import android.content.ComponentName
import android.graphics.Bitmap
import android.os.Process
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SelectedBrowseLayoutTest {
    @get:Rule val rule = createComposeRule()

    @Test fun changingLettersAndPointerHeightKeepsTheSameOriginButManualScrollingWorks() {
        val letter = mutableStateOf("A")
        val anchor = mutableStateOf(100f)
        val position = mutableStateOf(1f)
        val dragging = mutableStateOf(true)
        val apps = (1..24).map { app("Alpha %02d".format(it)) } + app("Beta")
        rule.setContent {
            PrismTheme(true, false, "neutral", .95f) {
                AlphabetApps(LauncherState(apps = apps, selectedIndexOnly = true, loading = false),
                    letter.value, anchor.value, position.value, dragging.value,
                    onLaunch = {}, onSelect = {}, onSearch = {}, onSettings = {}, onRetry = {})
            }
        }
        fun top(label: String) = rule.onNodeWithText(label).fetchSemanticsNode().boundsInRoot.top
        val initial = top("Alpha 01")
        val viewport = rule.onNodeWithTag("alphabet-app-list").fetchSemanticsNode().boundsInRoot
        val surface = rule.onNodeWithTag("alphabet-apps").fetchSemanticsNode().boundsInRoot
        // App text sits a few dp inside its row; account for that padding and system insets.
        assertTrue("First app begins near 35% of the screen", initial in
            (surface.top + surface.height * .32f)..(surface.top + surface.height * .43f))
        rule.runOnIdle { anchor.value = 1800f; position.value = 1.25f }
        assertEquals(initial, top("Alpha 01"), 2f)
        rule.runOnIdle { letter.value = "B"; position.value = 2f }
        rule.onNodeWithText("Alpha 01").assertDoesNotExist()
        assertEquals(initial, top("Beta"), 2f)
        rule.runOnIdle { dragging.value = false }
        assertEquals(initial, top("Beta"), 2f)
        rule.onNodeWithText("Alpha 24").assertIsDisplayed()
        // A sparse group must scroll too, and releasing/moving the index must not snap it back.
        rule.onNodeWithTag("alphabet-app-list").performTouchInput {
            swipe(Offset(centerX, height * .78f), Offset(centerX, height * .48f), 600)
        }
        val scrolled = top("Beta")
        assertTrue("The released list can move upward", scrolled < initial - viewport.height * .15f)
        rule.runOnIdle { anchor.value = 600f; position.value = 2.3f }
        assertEquals(scrolled, top("Beta"), 2f)
        rule.runOnIdle { dragging.value = true; letter.value = "C"; position.value = 3f }
        rule.onNodeWithText("Beta").assertDoesNotExist()
        val emptyLabel = InstrumentationRegistry.getInstrumentation().targetContext.getString(R.string.empty_index_section)
        rule.onNodeWithText(emptyLabel).assertIsDisplayed()
        assertTrue("Empty groups stay near the same origin, including their text padding",
            top(emptyLabel) in initial..(initial + surface.height * .03f))
        rule.runOnIdle { letter.value = "A"; position.value = 1f }
        assertEquals(initial, top("Alpha 01"), 2f)
        rule.onNodeWithTag("alphabet-app-list").performScrollToKey("Alpha 24")
        rule.onNodeWithText("Alpha 24").assertIsDisplayed()
    }

    @Test fun releaseKeepsSelectedPixelsStableAndRevealsNeighborsAcrossFrames() {
        val dragging = mutableStateOf(true)
        val apps = (1..24).map { app("Alpha %02d".format(it)) } + app("Beta")
        rule.setContent {
            PrismTheme(true, false, "neutral", .95f) {
                AlphabetApps(LauncherState(apps = apps, selectedIndexOnly = true, loading = false),
                    "B", 100f, 2f, dragging.value,
                    onLaunch = {}, onSelect = {}, onSearch = {}, onSettings = {}, onRetry = {})
            }
        }
        val selected = rule.onNodeWithTag("browse-app:B:Beta")
        val bounds = selected.fetchSemanticsNode().boundsInRoot
        val held = rule.onRoot().captureToImage().asAndroidBitmap()
        val heldApp = selected.captureToImage().asAndroidBitmap()
        rule.mainClock.autoAdvance = false
        rule.runOnIdle { dragging.value = false }
        val revealed = mutableListOf<Long>()
        repeat(16) {
            rule.mainClock.advanceTimeByFrame()
            rule.waitForIdle()
            assertEquals("Selected row must not move on release frame $it", bounds,
                selected.fetchSemanticsNode().boundsInRoot)
            assertTrue("Selected app must not blink or fade on release frame $it",
                heldApp.sameAs(selected.captureToImage().asAndroidBitmap()))
            val frame = rule.onRoot().captureToImage().asAndroidBitmap()
            revealed += pixelDifference(held, frame, bounds.top.toInt())
        }
        val fullyRevealed = revealed.last()
        assertTrue("Surrounding apps become visible", fullyRevealed > 1000)
        assertTrue("Neighbors appear over multiple frames rather than popping in: $revealed",
            revealed.count { it > fullyRevealed * .05 && it < fullyRevealed * .95 } >= 3)
        assertTrue("Reveal never flashes backward: $revealed", revealed.zipWithNext().all { (a, b) -> b >= a })
        rule.mainClock.autoAdvance = true
    }

    @Test fun fastSectionChangesShowTheLatestGroupAtTheAnchorOnTheFirstFrame() {
        val section = mutableStateOf("A")
        val apps = ('A'..'F').flatMap { letter -> (1..40).map { app("$letter %02d".format(it)) } }
        rule.setContent {
            PrismTheme(true, false, "neutral", .95f) {
                AlphabetApps(LauncherState(apps = apps, selectedIndexOnly = true, loading = false),
                    section.value, 100f, 1f, true,
                    onLaunch = {}, onSelect = {}, onSearch = {}, onSettings = {}, onRetry = {})
            }
        }
        val origin = rule.onNodeWithTag("browse-app:A:A 01").fetchSemanticsNode().boundsInRoot.top
        rule.mainClock.autoAdvance = false
        // Jump through virtualized groups in both directions without waiting for settling frames.
        for (letter in listOf("F", "B", "E", "C", "A", "D", "F", "A")) {
            rule.runOnIdle { section.value = letter }
            rule.mainClock.advanceTimeByFrame()
            rule.waitForIdle()
            val row = rule.onNodeWithTag("browse-app:$letter:$letter 01")
            row.assertIsDisplayed()
            assertEquals("The latest group must be aligned in its first frame", origin,
                row.fetchSemanticsNode().boundsInRoot.top, 2f)
            val pixels = row.captureToImage().asAndroidBitmap()
            var visiblePixels = 0
            for (y in 0 until pixels.height step 3) for (x in 0 until pixels.width step 3) {
                val pixel = pixels.getPixel(x, y)
                if ((pixel shr 16 and 255) > 100 && (pixel ushr 24) > 128) visiblePixels++
            }
            assertTrue("The new group must not have a blank frame", visiblePixels > 50)
        }
        rule.mainClock.autoAdvance = true
    }

    private fun pixelDifference(a: Bitmap, b: Bitmap, bottom: Int): Long {
        var difference = 0L
        for (y in 0 until bottom step 3) for (x in 0 until a.width step 3) {
            val before = a.getPixel(x, y)
            val after = b.getPixel(x, y)
            for (shift in listOf(0, 8, 16)) {
                difference += kotlin.math.abs((before shr shift and 255) - (after shr shift and 255))
            }
        }
        return difference
    }

    private fun app(label: String) = LauncherApp(label, label,
        ComponentName("app.prism.testfixture", label), Process.myUserHandle(), 0)
}
