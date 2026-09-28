package app.prism.launcher

import org.junit.Assert.*
import org.junit.Test

class AlphabetWaveTest {
    @Test fun sparseRibbonStillHasACurveAndMovesItsEnds() {
        val points = (0..10).map { AlphabetWave.letter(it, 11, 570f, 384f, 300f, 285f, 1f) }
        assertTrue("Sparse apps still form a visible arc", points.first().x - points[5].x > 45f)
        assertTrue("The ends still follow the thumb", 384f - points.first().x > 45f)
    }
    @Test fun distantLettersJoinThePullWithoutFlatteningTheApex() {
        val shallow = AlphabetWave.letter(2, 41, 570f, 384f, 368f, 285f, 1f)
        val deep = AlphabetWave.letter(2, 41, 570f, 384f, 224f, 285f, 1f)
        assertTrue("The far end joins the ribbon even on first touch", 384f - shallow.x > 20f)
        assertTrue("A deeper pull carries the distant rail inward", shallow.x - deep.x > 50f)
        val peak = AlphabetWave.letter(20, 41, 570f, 384f, 224f, 285f, 1f)
        val neighbor = AlphabetWave.letter(19, 41, 570f, 384f, 224f, 285f, 1f)
        assertTrue("The apex remains distinct", peak.x < neighbor.x && neighbor.x < deep.x)
    }

    @Test fun expandingTheWaveHasNoJumpAtEitherPullThreshold() {
        for (pull in listOf(32f, 160f)) for (index in 0..40) {
            val before = AlphabetWave.letter(index, 41, 570f, 384f, 384f - pull + .01f, 285f, 1f)
            val after = AlphabetWave.letter(index, 41, 570f, 384f, 384f - pull - .01f, 285f, 1f)
            assertEquals(before.x, after.x, .1f)
            assertEquals(before.y, after.y, .1f)
        }
    }
    @Test fun apexContinuesPastTheOldRailLimitWithoutSeparatingTheSelectedGlyph() {
        val xs = (360 downTo 160 step 10).map { fingerX ->
            val points = (0..40).map { AlphabetWave.letter(it, 41, 570f, 384f, fingerX.toFloat(), 285f, 1f) }
            val peak = points[20]
            assertTrue(peak.x <= fingerX - 79f)
            assertTrue(points[19].x > peak.x && points[21].x > peak.x)
            assertEquals(points[19].x, points[21].x, .01f)
            peak.x
        }
        assertTrue(xs.zipWithNext().all { (before, after) -> after < before - 9f })
    }

    @Test fun crossingALetterBoundaryDoesNotSnapTheCurve() {
        val boundary = 20f * 570f / 41f
        for (index in 0..40) {
            val before = AlphabetWave.letter(index, 41, 570f, 384f, 250f, boundary - .01f, 1f)
            val after = AlphabetWave.letter(index, 41, 570f, 384f, 250f, boundary + .01f, 1f)
            assertEquals(before.x, after.x, .1f)
            assertEquals(before.y, after.y, .1f)
        }
    }

    @Test fun activeLetterClearsThumbAndFollowsHorizontalPull() {
        for (fingerX in listOf(240f, 180f, 120f)) {
            val point = AlphabetWave.letter(20, 41, 570f, 240f, fingerX, 285f, 1f)
            assertTrue("Thumb clearance at $fingerX", point.x <= fingerX - 63f)
        }
    }
    @Test fun expandedBilingualRailRemainsOrderedAndInsideBounds() {
        for (pull in listOf(0f, 32f, 60f, 100f, 160f, 250f))
        for (focus in listOf(0f, 10f, 80f, 285f, 490f, 560f, 570f)) {
            val positions = (0..40).map { AlphabetWave.letter(it, 41, 570f, 384f, 384f - pull, focus, 1f) }
            assertTrue(positions.zipWithNext().all { (a, b) -> a.y < b.y })
            assertTrue(positions.all { it.y in 0f..570f && it.x >= 24f })
        }
    }
    @Test fun ribbonSpacingIsUniformWhileRestLayoutAndHitMappingStayStable() {
        for (count in listOf(15, 27, 41)) {
            val positions = (0 until count).map { AlphabetWave.letter(it, count, 570f, 384f, 250f, 285f, 1f) }
            val spacing = positions[1].y - positions[0].y
            positions.zipWithNext().forEach { (before, after) -> assertEquals(spacing, after.y - before.y, .01f) }
        }
        assertEquals(240f, AlphabetWave.letter(20, 41, 570f, 240f, 120f, 285f, 0f).x, .01f)
        assertEquals(0, AlphabetWave.indexAt(-30f, 570f, 41))
        assertEquals(40, AlphabetWave.indexAt(600f, 570f, 41))
    }

    @Test fun everyLetterKeepsItsVerticalPositionThroughoutTheGesture() {
        for (count in listOf(11, 27, 42)) for (index in 0 until count) {
            val rest = AlphabetWave.letter(index, count, 570f, 384f, 384f, 285f, 0f)
            for (focus in listOf(0f, 100f, 285f, 500f, 570f))
            for (pull in listOf(0f, 80f, 240f))
            for (openness in listOf(0f, .5f, 1f)) {
                val moved = AlphabetWave.letter(index, count, 570f, 384f, 384f - pull, focus, openness)
                assertEquals("Letter $index must not move vertically", rest.y, moved.y, 0f)
            }
        }
    }
}
