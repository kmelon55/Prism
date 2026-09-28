package app.prism.launcher

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitLongPressOrCancellation
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp

/** Pointer stays on the list while keyed rows move underneath it. */
internal class FavoriteDragState(val list: LazyListState) {
    var id by mutableStateOf<String?>(null)
    var top by mutableFloatStateOf(0f)
    var height by mutableFloatStateOf(0f)
    var pointerY by mutableFloatStateOf(0f)
    val translation: Float get() = top - (list.layoutInfo.visibleItemsInfo.find { it.key == id }?.offset ?: top.toInt())
    fun reorder(order: List<String>, move: (String, Int) -> Unit) {
        val dragged = id ?: return
        val center = top + height / 2
        // Empty space after the last row is still a valid drop at the end of the favorites.
        val target = list.layoutInfo.visibleItemsInfo.filter { it.key in order }
            .minByOrNull { kotlin.math.abs(it.offset + it.size / 2f - center) } ?: return
        val from = order.indexOf(dragged)
        val to = order.indexOf(target.key)
        if (from >= 0 && to >= 0 && from != to) {
            // Reordering the first visible key must not make LazyColumn jump to follow that key.
            list.requestScrollToItem(list.firstVisibleItemIndex, list.firstVisibleItemScrollOffset)
            move(dragged, to - from)
        }
    }
    fun stop() { id = null }
}

@Composable
internal fun rememberFavoriteDrag(list: LazyListState, favorites: List<String>, move: (String, Int) -> Unit): FavoriteDragState {
    val state = remember(list) { FavoriteDragState(list) }
    val order by rememberUpdatedState(favorites)
    val onMove by rememberUpdatedState(move)
    val edge = with(LocalDensity.current) { 64.dp.toPx() }
    val speed = with(LocalDensity.current) { 10.dp.toPx() }
    LaunchedEffect(state.id) {
        while (state.id != null) {
            withFrameNanos { }
            val info = list.layoutInfo
            val delta = when {
                state.pointerY < info.viewportStartOffset + edge -> -speed
                state.pointerY > info.viewportEndOffset - edge -> speed
                else -> 0f
            }
            if (delta != 0f) list.scrollBy(delta)
            if (delta != 0f) state.reorder(order, onMove)
        }
    }
    return state
}

@Composable
internal fun Modifier.favoriteDrag(state: FavoriteDragState, favorites: List<String>, move: (String, Int) -> Unit, onEmptyLongPress: () -> Unit): Modifier {
    val order by rememberUpdatedState(favorites)
    val onMove by rememberUpdatedState(move)
    val onEmpty by rememberUpdatedState(onEmptyLongPress)
    val haptic = LocalHapticFeedback.current
    return pointerInput(state) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            // Lazy item offsets exclude beforeContentPadding; pointer coordinates include it.
            val y = down.position.y - state.list.layoutInfo.beforeContentPadding
            val item = state.list.layoutInfo.visibleItemsInfo.find {
                y in it.offset.toFloat()..(it.offset + it.size).toFloat()
            }
            if (item?.key !in order) {
                if (item == null && awaitLongPressOrCancellation(down.id) != null) onEmpty()
                return@awaitEachGesture
            }
            val held = awaitLongPressOrCancellation(down.id) ?: return@awaitEachGesture
            held.consume()
            state.id = item!!.key as String
            state.top = item.offset.toFloat()
            state.height = item.size.toFloat()
            state.pointerY = y
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            try {
                while (true) {
                    // Claim movement before LazyColumn's scroll detector once the hold has picked up an app.
                    val change = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed) { change.consume(); break }
                    val delta = change.positionChange()
                    change.consume()
                    state.top += delta.y
                    state.pointerY = change.position.y - state.list.layoutInfo.beforeContentPadding
                    state.reorder(order, onMove)
                }
            } finally { state.stop() }
        }
    }
}
