package app.prism.launcher

import org.junit.Assert.*
import org.junit.Test

class WidgetStackTest {
    private val first = WidgetSlot(11, 180)
    private val second = WidgetSlot(22, 240)
    private val third = WidgetSlot(33, 300)

    @Test fun additionsRetainExistingWidgetsAndSelectTheNewOne() {
        val stack = WidgetStack(listOf(first), first.id).add(second)
        assertEquals(listOf(first, second), stack.slots)
        assertEquals(second, stack.active)
        assertEquals(first, stack.step(1).active)
        assertEquals(second, stack.step(1).step(-1).active)
    }

    @Test fun resizeOnlyAffectsTheSelectedWidget() {
        val stack = WidgetStack(listOf(first, second), second.id).resize(360)
        assertEquals(first, stack.select(first.id).active)
        assertEquals(360, stack.active?.height)
    }

    @Test fun removingActiveChoosesItsNeighborAndPreservesRemainingSizes() {
        val stack = WidgetStack(listOf(first, second, third), second.id).remove(second.id)
        assertEquals(listOf(first, third), stack.slots)
        assertEquals(third, stack.active)
        assertEquals(first, stack.remove(third.id).active)
        assertNull(stack.remove(third.id).remove(first.id).active)
    }

    @Test fun removingOtherWidgetDoesNotChangeSelection() {
        assertEquals(second, WidgetStack(listOf(first, second), second.id).remove(first.id).active)
    }

    @Test fun missingRestoredSelectionFallsBackAndUnknownSelectionIsIgnored() {
        val stack = WidgetStack(listOf(first, second), 999)
        assertEquals(first, stack.active)
        assertEquals(stack, stack.select(555))
        assertEquals(second, stack.step(-1).active)
    }

    @Test fun emptyStacksAndDuplicateCommitsStayValid() {
        assertEquals(WidgetStack(), WidgetStack().step(1))
        val stack = WidgetStack().add(first).add(first.copy(height = 200))
        assertEquals(1, stack.slots.size)
        assertEquals(200, stack.active?.height)
        assertNull(stack.remove(first.id).active)
    }
}
