package app.prism.launcher

import org.junit.Assert.*
import org.junit.Test

class AlphabetWaveTest {
    @Test fun activeLetterClearsThumbAndFollowsHorizontalPull() {
        for (fingerX in listOf(240f, 180f, 120f)) {
            val point = AlphabetWave.letter(20, 41, 570f, 240f, fingerX, 285f, 1f)
            assertTrue("Thumb clearance at $fingerX", point.x <= fingerX - 63f)
        }
    }
    @Test fun expandedBilingualRailRemainsOrderedAndInsideBounds() {
        for (focus in listOf(0f, 10f, 80f, 285f, 490f, 560f, 570f)) {
            val positions = (0..40).map { AlphabetWave.letter(it, 41, 570f, 240f, 180f, focus, 1f) }
            assertTrue(positions.zipWithNext().all { (a, b) -> a.y < b.y })
            assertTrue(positions.all { it.y in 0f..570f && it.x >= 24f })
        }
    }
    @Test fun neighborsSpreadWhileRestLayoutAndHitMappingStayStable() {
        val before = AlphabetWave.letter(19, 41, 570f, 240f, 240f, 285f, 1f)
        val after = AlphabetWave.letter(21, 41, 570f, 240f, 240f, 285f, 1f)
        assertTrue(after.y - before.y > 40f)
        assertEquals(240f, AlphabetWave.letter(20, 41, 570f, 240f, 120f, 285f, 0f).x, .01f)
        assertEquals(0, AlphabetWave.indexAt(-30f, 570f, 41))
        assertEquals(40, AlphabetWave.indexAt(600f, 570f, 41))
    }
}
