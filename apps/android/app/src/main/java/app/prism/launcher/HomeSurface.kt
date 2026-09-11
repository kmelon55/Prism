@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package app.prism.launcher

import android.appwidget.AppWidgetManager
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt

/** Include the relevant alphabets, even when a letter currently has no installed apps. */
internal fun alphabetSections(labels: List<String>): List<String> {
    val present = labels.map(AppSearch::section).toSet()
    val letters = AppSearch.sectionOrder.filter {
        when {
            it == "#" -> "#" in present
            it.first() in 'A'..'Z' -> present.any { section -> section.first() in 'A'..'Z' }
            else -> present.any { section -> section.first() in 'ㄱ'..'ㅎ' }
        }
    }
    return listOf("★") + letters
}

@Composable
internal fun HomeScreen(
    state: LauncherState, widgets: WidgetController, editing: Boolean,
    onLaunch: (LauncherApp) -> Unit, onSearch: () -> Unit, onAllApps: () -> Unit,
    onSettings: () -> Unit, onSelect: (LauncherApp) -> Unit,
    onMove: (String, Int) -> Unit, onEdit: () -> Unit, onLock: () -> Unit,
    defaultHome: Boolean, onChooseHome: () -> Unit,
) {
    val favorites = remember(state.apps, state.favorites) {
        val byId = state.apps.associateBy(LauncherApp::id)
        state.favorites.mapNotNull(byId::get)
    }
    val widgetId by widgets.activeId.collectAsStateWithLifecycle()
    val threshold = with(LocalDensity.current) { 56.dp.toPx() }
    val latestSearch by rememberUpdatedState(onSearch)
    val latestSettings by rememberUpdatedState(onSettings)
    val latestLock by rememberUpdatedState(onLock)
    val searchScroll = remember(threshold) {
        object : NestedScrollConnection {
            var distance = 0f
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput) {
                    if (available.y < 0) distance += available.y else distance = 0f
                    if (distance < -threshold) { distance = 0f; latestSearch() }
                }
                return Offset.Zero
            }
            override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
                distance = 0f
                return Velocity.Zero
            }
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().testTag("home-surface")
        .nestedScroll(searchScroll).pointerInput(Unit) {
            detectTapGestures(onLongPress = { latestSettings() }, onDoubleTap = { latestLock() })
        }) {
        val topSpace = (maxHeight * .12f).coerceIn(36.dp, 108.dp)
        LazyColumn(
            Modifier.fillMaxSize().padding(end = 64.dp),
            contentPadding = PaddingValues(start = 32.dp, top = topSpace, bottom = 108.dp),
        ) {
            if (editing) item("edit") {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.edit_home), Modifier.weight(1f), color = Muted, fontSize = 13.sp)
                    TextButton(onClick = onEdit) { Text(stringResource(R.string.done)) }
                }
            }
            if (!defaultHome) item("default") {
                TextButton(onClick = onChooseHome) { Text(stringResource(R.string.choose_home)) }
            }
            item("clock") {
                // A custom widget replaces the built-in clock; never show two clocks by default.
                if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
                    Box(Modifier.combinedClickable(onClick = onSettings, onLongClick = onEdit,
                        onDoubleClick = onLock, onClickLabel = stringResource(R.string.settings),
                        onLongClickLabel = stringResource(R.string.edit_home))) { HomeClock() }
                } else HomeWidget(widgets)
                Spacer(Modifier.height(36.dp))
            }
            if (state.loading && favorites.isEmpty()) item { Text(stringResource(R.string.loading), color = Muted) }
            if (!state.loading && favorites.isEmpty()) item {
                TextButton(onClick = onAllApps, contentPadding = PaddingValues(0.dp)) {
                    Text(stringResource(R.string.choose_favorites), color = Paper, fontSize = 22.sp, fontWeight = FontWeight.Light)
                }
            }
            items(favorites, key = LauncherApp::id) { app ->
                Row(Modifier.fillMaxWidth().heightIn(min = 58.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(app.label,
                        Modifier.weight(1f).combinedClickable(
                            onClick = { if (editing) onSelect(app) else onLaunch(app) },
                            onLongClick = { onSelect(app) }, onLongClickLabel = stringResource(R.string.app_info),
                        ).padding(vertical = 12.dp),
                        color = Paper, fontSize = 27.sp, fontWeight = FontWeight.Light,
                        letterSpacing = (-.5).sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (editing) {
                        val index = state.favorites.indexOf(app.id)
                        IconButton(onClick = { onMove(app.id, -1) }, enabled = index > 0) {
                            Icon(Icons.Rounded.KeyboardArrowUp, stringResource(R.string.move_up))
                        }
                        IconButton(onClick = { onMove(app.id, 1) }, enabled = index < state.favorites.lastIndex) {
                            Icon(Icons.Rounded.KeyboardArrowDown, stringResource(R.string.move_down))
                        }
                    }
                }
            }
        }
        IconButton(onClick = onSearch, modifier = Modifier.align(Alignment.BottomStart).padding(start = 24.dp, bottom = 24.dp)) {
            Icon(Icons.Rounded.Search, stringResource(R.string.search_apps), tint = Muted, modifier = Modifier.size(21.dp))
        }
        // A regular button is also available to TalkBack and switch-access users.
        IconButton(onClick = onAllApps, modifier = Modifier.align(Alignment.BottomEnd).padding(end = 12.dp, bottom = 24.dp)) {
            Icon(Icons.Rounded.MoreHoriz, stringResource(R.string.all_apps), tint = Muted, modifier = Modifier.size(21.dp))
        }
    }
}

@Composable
private fun HomeClock() {
    var now by remember { mutableStateOf(LocalDateTime.now()) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                now = LocalDateTime.now()
                delay(60_000L - System.currentTimeMillis() % 60_000L)
            }
        }
    }
    val context = LocalContext.current
    val locale = LocalConfiguration.current.locales[0]
    val pattern = if (android.text.format.DateFormat.is24HourFormat(context)) "HH:mm" else "h:mm"
    Column {
        Text(now.format(DateTimeFormatter.ofPattern(pattern)), fontSize = 46.sp,
            fontWeight = FontWeight.Light, letterSpacing = (-2).sp, color = Paper)
        Spacer(Modifier.height(4.dp))
        Text(now.format(DateTimeFormatter.ofPattern(
            android.text.format.DateFormat.getBestDateTimePattern(locale, "MMMEd"), locale)),
            color = Muted, fontSize = 13.sp)
    }
}

@Composable
internal fun AlphabetRail(
    sections: List<String>, selected: String?, dragging: Boolean, modifier: Modifier = Modifier,
    onDragging: (Boolean) -> Unit, onSection: (String) -> Unit,
) {
    val latestSelect by rememberUpdatedState(onSection)
    val latestDragging by rememberUpdatedState(onDragging)
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    val railHeight = (LocalConfiguration.current.screenHeightDp.dp * .64f).coerceIn(300.dp, 600.dp)
    val railWidth = 264.dp
    val restX = railWidth.value - 24f
    var fingerX by remember { mutableFloatStateOf(restX) }
    var fingerY by remember { mutableFloatStateOf(railHeight.value / 2f) }
    val openness by animateFloatAsState(if (dragging) 1f else 0f,
        animationSpec = spring(dampingRatio = .85f, stiffness = 900f), label = "alphabet-opening")
    Box(modifier.width(railWidth).height(railHeight).testTag("alphabet-wave")) {
        // Only a quiet handle remains at rest. The alphabet unfolds around the actual pointer.
        Box(Modifier.align(Alignment.CenterEnd).padding(end = 23.dp).width(2.dp).height(32.dp)
            .graphicsLayer { alpha = (1f - openness) * .35f }.background(Muted, CircleShape))
        sections.forEachIndexed { index, section ->
            val point = AlphabetWave.letter(index, sections.size, railHeight.value, restX,
                fingerX, fingerY, openness)
            val active = dragging && selected == section
            val description = if (section == "★") stringResource(R.string.favorites)
                else stringResource(R.string.jump_to_letter, section)
            Box(Modifier.offset { IntOffset(with(density) { (point.x - 20f).dp.toPx() }.roundToInt(),
                    with(density) { (point.y - 20f).dp.toPx() }.roundToInt()) }
                .size(40.dp).graphicsLayer { alpha = openness.coerceIn(0f, 1f) }
                .then(if (active) Modifier.testTag("alphabet-preview") else Modifier)
                .semantics(mergeDescendants = true) {
                    contentDescription = description; role = Role.Button
                    onClick { latestSelect(section); true }
                }, contentAlignment = Alignment.Center) {
                if (active) Box(Modifier.size(36.dp).background(Paper.copy(alpha = .16f), CircleShape))
                Text(section,
                    fontSize = ((if (active) 22f else 11f + 5f * point.emphasis) / density.fontScale.coerceAtLeast(1f)).sp,
                    lineHeight = (26f / density.fontScale.coerceAtLeast(1f)).sp,
                    maxLines = 1, overflow = TextOverflow.Visible,
                    style = androidx.compose.ui.text.TextStyle(platformStyle =
                        androidx.compose.ui.text.PlatformTextStyle(includeFontPadding = false)),
                    color = if (active) Paper else Muted,
                    fontWeight = if (active) FontWeight.Medium else FontWeight.Normal)
            }
        }
        // This hit region never moves or grows with the visual wave. A held pointer may move left
        // outside it; its x position still pulls the visible alphabet away from the user's thumb.
        Box(Modifier.align(Alignment.CenterEnd).width(48.dp).fillMaxHeight()
            .testTag("alphabet-rail").semantics { stateDescription = selected ?: "★" }
            .pointerInput(sections, density.density, railHeight) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    down.consume()
                    var last = -1
                    fun select(position: Offset) {
                        fingerX = railWidth.value - 48f + position.x / density.density
                        fingerY = (position.y / density.density).coerceIn(0f, railHeight.value)
                        val index = AlphabetWave.indexAt(position.y, size.height.toFloat(), sections.size)
                        if (last != index) {
                            last = index
                            latestSelect(sections[index])
                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        }
                    }
                    latestDragging(true)
                    try {
                        select(down.position)
                        drag(down.id) { change -> change.consume(); select(change.position) }
                    } finally { latestDragging(false) }
                }
            })
    }
}

@Composable
internal fun AlphabetApps(
    state: LauncherState, section: String?, onLaunch: (LauncherApp) -> Unit,
    onSelect: (LauncherApp) -> Unit, onBack: () -> Unit, onSearch: () -> Unit,
    onSettings: () -> Unit, onRetry: () -> Unit,
) {
    val listState = rememberLazyListState()
    val listBottomSpace = (LocalConfiguration.current.screenHeightDp - 200).coerceAtLeast(200).dp
    val groups = remember(state.apps) { state.apps.groupBy { AppSearch.section(it.label) }.toList() }
    val positions = remember(groups) {
        var position = 0
        groups.associate { (letter, apps) -> (letter to position).also { position += apps.size + 1 } }
    }
    LaunchedEffect(section, positions) {
        if (section != null && positions.isNotEmpty()) {
            val order = AppSearch.sectionOrder.indexOf(section)
            val next = positions.keys.firstOrNull { AppSearch.sectionOrder.indexOf(it) >= order } ?: positions.keys.last()
            listState.scrollToItem(positions.getValue(next))
        }
    }
    Box(Modifier.fillMaxSize().safeDrawingPadding().testTag("alphabet-apps")) {
        Column(Modifier.fillMaxSize().padding(end = 64.dp)) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back), tint = Muted) }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onSettings) { Icon(Icons.Rounded.Tune, stringResource(R.string.settings), tint = Muted, modifier = Modifier.size(20.dp)) }
            }
            if (state.error) TextButton(onClick = onRetry) { Text(stringResource(R.string.retry)) }
            if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            LazyColumn(state = listState, modifier = Modifier.weight(1f).fillMaxWidth().testTag("alphabet-app-list"),
                contentPadding = PaddingValues(start = 28.dp, end = 8.dp, bottom = listBottomSpace)) {
                groups.forEach { (letter, apps) ->
                    item("section:$letter") {
                        Text(letter, Modifier.padding(start = 8.dp, top = 18.dp, bottom = 14.dp), color = Muted,
                            fontSize = 14.sp, fontWeight = FontWeight.Medium)
                    }
                    items(apps, key = LauncherApp::id) { app ->
                        AppRow(app, null, onClick = { onLaunch(app) }, onLongClick = { onSelect(app) })
                    }
                }
                if (!state.loading && state.apps.isEmpty()) item { Text(stringResource(R.string.empty_apps), color = Muted) }
            }
        }
        IconButton(onClick = onSearch, modifier = Modifier.align(Alignment.BottomStart).padding(start = 24.dp, bottom = 24.dp)
            .background(Ink, androidx.compose.foundation.shape.CircleShape)) {
            Icon(Icons.Rounded.Search, stringResource(R.string.search_apps), tint = Muted, modifier = Modifier.size(21.dp))
        }
    }
}
