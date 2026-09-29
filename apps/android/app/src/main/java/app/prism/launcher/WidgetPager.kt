package app.prism.launcher

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/** Page identity follows the widget ID; provider clicks and vertical scrolling stay native. */
@Composable
internal fun WidgetPager(stack: WidgetStack, onSelect: (Int) -> Unit, content: @Composable (WidgetSlot) -> Unit) {
    if (stack.slots.isEmpty()) return
    key(stack.slots.map { it.id }) {
        val pager = rememberPagerState(initialPage = stack.slots.indexOf(stack.active).coerceAtLeast(0)) { stack.slots.size }
        val latestSelect by rememberUpdatedState(onSelect)
        val scope = rememberCoroutineScope()
        LaunchedEffect(pager.settledPage) { latestSelect(stack.slots[pager.settledPage].id) }
        Column {
            HorizontalPager(state = pager, key = { stack.slots[it].id }, verticalAlignment = Alignment.Top,
                modifier = Modifier.fillMaxWidth().testTag("widget-pager")) { index ->
                Box(Modifier.fillMaxWidth().padding(horizontal = 2.dp)) { content(stack.slots[index]) }
            }
            if (stack.slots.size > 1) Row(Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { scope.launch { pager.animateScrollToPage(Math.floorMod(pager.currentPage - 1, stack.slots.size)) } }) {
                    Icon(Icons.Rounded.ChevronLeft, stringResource(R.string.previous_widget))
                }
                // Dots also provide a reliable swipe area for widgets that own horizontal gestures.
                Row(Modifier.swipeHorizontal(
                    onLeft = { scope.launch { pager.animateScrollToPage((pager.currentPage + 1) % stack.slots.size) } },
                    onRight = { scope.launch { pager.animateScrollToPage(Math.floorMod(pager.currentPage - 1, stack.slots.size)) } })
                    .padding(horizontal = 8.dp, vertical = 16.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    stack.slots.forEachIndexed { index, _ ->
                        Box(Modifier.size(if (index == pager.currentPage) 7.dp else 5.dp)
                            .background(if (index == pager.currentPage) PrismAccent else Muted.copy(alpha = .4f), CircleShape))
                    }
                }
                Text(stringResource(R.string.widget_position, pager.currentPage + 1, stack.slots.size),
                    Modifier.testTag("widget-page-position"), color = Muted, style = MaterialTheme.typography.labelSmall)
                IconButton(onClick = { scope.launch { pager.animateScrollToPage((pager.currentPage + 1) % stack.slots.size) } }) {
                    Icon(Icons.Rounded.ChevronRight, stringResource(R.string.next_widget))
                }
            }
        }
    }
}
