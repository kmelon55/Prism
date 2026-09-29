package app.prism.launcher

import org.junit.Assert.*
import org.junit.Test

class AlphabetBrowseTest {
    @Test fun selectedGroupStartsAtThumbHeightAcrossScreenSizes() {
        assertEquals(280f, selectedBrowseAnchor(800f, 728f, 58f), .01f)
        assertEquals(420f, selectedBrowseAnchor(1200f, 1128f, 58f), .01f)
        assertEquals(105f, selectedBrowseAnchor(300f, 228f, 33f), .01f)
    }

    @Test fun selectedGroupKeepsACompleteRowOnShortOrLargeTextScreens() {
        assertEquals(110f, selectedBrowseAnchor(500f, 228f, 118f), .01f)
        assertEquals(0f, selectedBrowseAnchor(100f, 28f, 118f), .01f)
    }

    @Test fun lazyTargetUsesTheContainingRowAtBoundariesAndLargeOffsets() {
        val rows = listOf(0f, 40f, 100f, 160f, 200f, 260f)
        assertEquals(0, browseItemAt(rows, -300f))
        assertEquals(1, browseItemAt(rows, 99.99f))
        assertEquals(2, browseItemAt(rows, 100f))
        assertEquals(5, browseItemAt(rows, 500f))
    }
    private val stops = listOf(BrowseStop(2f, 40f), BrowseStop(5f, 260f), BrowseStop(8f, 480f))

    @Test fun missingLettersAndSectionBoundariesRemainContinuous() {
        assertEquals(150f, interpolateBrowseOffset(stops, 3.5f), .01f)
        assertEquals(260f, interpolateBrowseOffset(stops, 5f), .01f)
        val positions = (0..100).map { interpolateBrowseOffset(stops, 2f + it * .06f) }
        assertTrue(positions.zipWithNext().all { (a, b) -> b > a && b - a < 5f })
        assertEquals(interpolateBrowseOffset(stops, 4.999f), interpolateBrowseOffset(stops, 5.001f), .2f)
    }

    @Test fun emptyAndSingleGroupsHaveSafeBounds() {
        assertEquals(0f, interpolateBrowseOffset(emptyList(), 2f), 0f)
        assertEquals(40f, interpolateBrowseOffset(stops.take(1), 20f), 0f)
        assertEquals(40f, interpolateBrowseOffset(stops, -1f), 0f)
        assertEquals(480f, interpolateBrowseOffset(stops, 90f), 0f)
    }
}
