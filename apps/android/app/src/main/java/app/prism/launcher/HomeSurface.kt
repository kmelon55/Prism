@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package app.prism.launcher

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.clickable
import androidx.compose.ui.zIndex
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
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
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
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

/** Keep every index slot available; filtering empty groups is opt-in. */
internal fun alphabetSections(labels: List<String>, showAll: Boolean = true, showKorean: Boolean = true): List<String> {
    val order = AppIndex.order(showKorean)
    if (showAll) return listOf("★") + order
    val present = labels.map { AppIndex.section(it, it, showKorean) }.toSet()
    return listOf("★") + order.filter { it in present }
}

internal fun alphabetLabel(section: String, syllables: Boolean): String {
    val index = "ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎ".indexOf(section)
    return if (syllables && index >= 0 && section.length == 1) "가나다라마바사아자차카타파하"[index].toString() else section
}

@Composable
internal fun HomeScreen(
    state: LauncherState, widgets: WidgetController, editing: Boolean,
    onLaunch: (LauncherApp) -> Unit, onSearch: () -> Unit, onChooseFavorites: () -> Unit,
    onSettings: () -> Unit, onSelect: (LauncherApp) -> Unit,
    onFolder: (String) -> Unit, onEditFolder: (String?) -> Unit, onMoveFolder: (String, Int) -> Unit,
    onMove: (String, Int) -> Unit, onEdit: () -> Unit, onLock: () -> Unit,
    defaultHome: Boolean, onChooseHome: () -> Unit,
) {
    val favorites = remember(state.apps, state.favorites) {
        val byId = state.apps.associateBy(LauncherApp::id)
        state.favorites.mapNotNull(byId::get)
    }
    val listState = rememberLazyListState()
    val drag = rememberFavoriteDrag(listState, state.favorites, onMove)
    val widgetId by widgets.activeId.collectAsStateWithLifecycle()
    val threshold = with(LocalDensity.current) { 56.dp.toPx() }
    val searchLabel = stringResource(R.string.search_apps)
    val latestSearch by rememberUpdatedState(onSearch)
    val latestSettings by rememberUpdatedState(onSettings)
    val latestLock by rememberUpdatedState(onLock)
    val searchScroll = remember(threshold) {
        object : NestedScrollConnection {
            var distance = 0f
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput && drag.id == null) {
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
        .nestedScroll(searchScroll)) {
        val topSpace = (maxHeight * .07f).coerceIn(24.dp, 52.dp)
        LazyColumn(
            Modifier.fillMaxSize().padding(end = 52.dp, bottom = 40.dp)
                .testTag("home-list").favoriteDrag(drag, state.favorites, onMove, onSettings),
            state = listState,
            contentPadding = PaddingValues(start = 24.dp, top = topSpace, bottom = 24.dp),
        ) {
            if (editing) item("edit") {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.edit_home), Modifier.weight(1f), color = Muted, fontSize = 13.sp)
                    TextButton(onClick = onEdit) { Text(stringResource(R.string.done)) }
                }
            }
            if (!defaultHome) item("default") {
                TextButton(onClick = onChooseHome, contentPadding = PaddingValues(horizontal = 8.dp)) {
                    Icon(Icons.Rounded.Home, null, Modifier.size(16.dp), tint = Muted)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.choose_home), color = Muted, fontSize = 13.sp)
                }
            }
            if (state.showClock || widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) item("clock") {
                // A custom widget replaces the built-in clock; never show two clocks by default.
                if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
                    Box(Modifier.fillMaxWidth().combinedClickable(onClick = onSettings, onLongClick = onEdit,
                        onDoubleClick = onLock, onClickLabel = stringResource(R.string.settings),
                        onLongClickLabel = stringResource(R.string.edit_home))) { HomeClock() }
                } else HomeWidget(widgets)
                Spacer(Modifier.height(28.dp))
            }
            if (state.loading && favorites.isEmpty()) item { Text(stringResource(R.string.loading), color = Muted) }
            items(favorites, key = LauncherApp::id) { app ->
                val dragging = drag.id == app.id
                val actionsLabel = stringResource(R.string.app_actions)
                val upLabel = stringResource(R.string.move_up)
                val downLabel = stringResource(R.string.move_down)
                Row(Modifier.fillMaxWidth().animateItem(fadeInSpec = null, fadeOutSpec = null,
                    placementSpec = if (dragging) null else spring(stiffness = 500f))
                    .zIndex(if (dragging) 1f else 0f)
                    .graphicsLayer { translationY = if (dragging) drag.translation else 0f; scaleX = if (dragging) 1.035f else 1f; scaleY = scaleX }
                    .then(if (dragging) Modifier.prismPanel(LocalPrismEffects.current, 18.dp, false) else Modifier)
                    .testTag("home-favorite-${app.id}")
                    .semantics {
                        customActions = listOf(
                            CustomAccessibilityAction(upLabel) { onMove(app.id, -1); true },
                            CustomAccessibilityAction(downLabel) { onMove(app.id, 1); true },
                            CustomAccessibilityAction(actionsLabel) { onSelect(app); true },
                        )
                    }
                    .swipeRight { onSelect(app) }
                    .clickable { if (editing) onSelect(app) else onLaunch(app) }
                    .padding(horizontal = 8.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    AppIcon(app)
                    Spacer(Modifier.width(24.dp))
                    Text(app.label, Modifier.weight(1f), color = Paper, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (editing || dragging) Icon(Icons.Rounded.DragHandle, null, tint = Muted, modifier = Modifier.size(20.dp))
                }
            }
            item("add-favorites") {
                TextButton(onClick = onChooseFavorites, modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
                    .testTag("add-favorites").prismPanel(LocalPrismEffects.current, 20.dp, luminous = false),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp)) {
                    Icon(Icons.Rounded.Add, null, Modifier.size(20.dp), tint = Muted)
                    Spacer(Modifier.width(20.dp))
                    Text(stringResource(R.string.add_favorites), Modifier.weight(1f), color = Paper, fontSize = 14.sp)
                }
            }
            items(state.folders, key = { "folder:${it.id}" }) { folder ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    FolderRow(folder, Modifier.weight(1f), onOpen = { onFolder(folder.id) }, onEdit = { onEditFolder(folder.id) })
                    if (editing) {
                        val index = state.folders.indexOf(folder)
                        IconButton(onClick = { onMoveFolder(folder.id, -1) }, enabled = index > 0) {
                            Icon(Icons.Rounded.KeyboardArrowUp, stringResource(R.string.move_up))
                        }
                        IconButton(onClick = { onMoveFolder(folder.id, 1) }, enabled = index < state.folders.lastIndex) {
                            Icon(Icons.Rounded.KeyboardArrowDown, stringResource(R.string.move_down))
                        }
                    }
                }
            }
            if (editing) item("create-folder") {
                TextButton(onClick = { onEditFolder(null) }, modifier = Modifier.testTag("create-folder")) {
                    Icon(Icons.Rounded.CreateNewFolder, null)
                    Spacer(Modifier.width(12.dp))
                    Text(stringResource(R.string.create_folder))
                }
            }

        }
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 48.dp).height(40.dp)
            .testTag("home-search-gesture").semantics {
                onClick(label = searchLabel) { latestSearch(); true }
            }.pointerInput(Unit) {
                detectTapGestures(onLongPress = { latestSettings() }, onDoubleTap = { latestLock() })
            }.pointerInput(threshold) {
                var distance = 0f
                detectVerticalDragGestures(onDragStart = { distance = 0f },
                    onDragCancel = { distance = 0f }, onDragEnd = { distance = 0f },
                    onVerticalDrag = { change, delta ->
                        change.consume()
                        distance = (distance - delta).coerceAtLeast(0f)
                        if (distance >= threshold) { distance = 0f; latestSearch() }
                    })
            })

    }
}

@Composable
private fun HomeClock() {
    var now by remember { mutableStateOf(LocalDateTime.now()) }
    var battery by remember { mutableIntStateOf(-1) }
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle, context) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                now = LocalDateTime.now()
                val status = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                val level = status?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                val scale = status?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                battery = if (level >= 0 && scale > 0) level * 100 / scale else -1
                delay(60_000L - System.currentTimeMillis() % 60_000L)
            }
        }
    }
    val locale = LocalConfiguration.current.locales[0]
    val twentyFourHour = android.text.format.DateFormat.is24HourFormat(context)
    val pattern = if (twentyFourHour) "HH:mm" else "hh:mm"
    PrismPanel(Modifier.fillMaxWidth().testTag("prism-clock")) {
        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(now.format(DateTimeFormatter.ofPattern(
                    android.text.format.DateFormat.getBestDateTimePattern(locale, "MMMEd"), locale)),
                    Modifier.weight(1f), color = Muted, fontSize = 13.sp)
                if (!twentyFourHour) Text(now.format(DateTimeFormatter.ofPattern("a", locale)),
                    color = PrismAccent, fontSize = 11.sp)
            }
            Text(now.format(DateTimeFormatter.ofPattern(pattern)), color = Paper, fontSize = 56.sp,
                fontWeight = FontWeight.Light, letterSpacing = (-2).sp, modifier = Modifier.testTag("home-clock-time"))
            PrismRule()
            if (battery >= 0) Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(32.dp), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.BatteryFull, null, Modifier.size(20.dp), tint = Muted)
                }
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.battery_level, battery), color = Muted, fontSize = 12.sp)
            }
        }
    }
}

@Composable
internal fun AlphabetRail(
    sections: List<String>, selected: String?, dragging: Boolean, modifier: Modifier = Modifier,
    onDragging: (Boolean) -> Unit, onSection: (String, Float, Float) -> Unit,
    fromStart: Boolean = false, koreanSyllables: Boolean = true,
) {
    val latestSelect by rememberUpdatedState(onSection)
    val latestDragging by rememberUpdatedState(onDragging)
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    val railHeight = (LocalConfiguration.current.screenHeightDp.dp * .72f).coerceIn(300.dp, 660.dp)
    val railWidth = LocalConfiguration.current.screenWidthDp.dp
    val expandedFontSize = minOf(17f, railHeight.value / sections.size.coerceAtLeast(1) * .9f)
    val restingFontSize = minOf(12f, expandedFontSize)
    var railTop by remember { mutableFloatStateOf(0f) }
    val hitWidth = if (fromStart) 24.dp else 48.dp
    val restX = railWidth.value - 24f
    var fingerX by remember { mutableFloatStateOf(restX) }
    var fingerY by remember { mutableFloatStateOf(railHeight.value / 2f) }
    val openness by animateFloatAsState(if (dragging) 1f else 0f,
        animationSpec = spring(dampingRatio = 1f, stiffness = 900f), label = "alphabet-opening")
    Box(modifier.width(railWidth).height(railHeight).onGloballyPositioned { railTop = it.positionInRoot().y }.testTag(if (fromStart) "alphabet-wave-left" else "alphabet-wave")) {
        // Keep a quiet alphabet visible on the right so the browsing gesture is discoverable.
        sections.forEachIndexed { index, section ->
            val point = AlphabetWave.letter(index, sections.size, railHeight.value, restX,
                fingerX, fingerY, openness)
            val description = if (section == "★") stringResource(R.string.favorites)
                else stringResource(R.string.jump_to_letter, section)
            Box(Modifier.offset { IntOffset(with(density) { ((if (fromStart) railWidth.value - point.x else point.x) - 20f).dp.toPx() }.roundToInt(),
                    with(density) { (point.y - 20f).dp.toPx() }.roundToInt()) }
                .size(40.dp).testTag("alphabet-letter-${if (fromStart) "left-" else ""}$section").graphicsLayer { alpha = if (fromStart) openness.coerceIn(0f, 1f) else .35f + .65f * openness.coerceIn(0f, 1f) }
                .semantics(mergeDescendants = true) {
                    contentDescription = description; role = Role.Button
                    onClick { latestSelect(section, railTop + with(density) { railHeight.toPx() } / 2f, index.toFloat()); true }
                }.then(if (fromStart && !dragging) Modifier.clearAndSetSemantics {} else Modifier), contentAlignment = Alignment.Center) {
                Text(alphabetLabel(section, koreanSyllables),
                    fontSize = ((restingFontSize + (expandedFontSize - restingFontSize) * openness.coerceIn(0f, 1f)) / density.fontScale.coerceAtLeast(1f)).sp,
                    lineHeight = (26f / density.fontScale.coerceAtLeast(1f)).sp,
                    maxLines = 1, overflow = TextOverflow.Visible,
                    style = androidx.compose.ui.text.TextStyle(platformStyle =
                        androidx.compose.ui.text.PlatformTextStyle(includeFontPadding = false)),
                    color = if (section == selected) PrismAccent else Paper, fontWeight = FontWeight.Normal)
            }
        }
        if (dragging && selected != null) {
            val index = sections.indexOf(selected).coerceAtLeast(0)
            val point = AlphabetWave.letter(index, sections.size, railHeight.value, restX, fingerX, fingerY, openness)
            val previewX = (if (fromStart) railWidth.value - point.x + 36f else point.x - 36f)
                .coerceIn(22f, railWidth.value - 22f)
            Box(Modifier.offset {
                IntOffset(with(density) { (previewX - 22f).dp.roundToPx() }, with(density) { (point.y - 22f).dp.roundToPx() })
            }.size(44.dp).semantics(mergeDescendants = true) {}
                .testTag(if (fromStart) "alphabet-preview-left" else "alphabet-preview"), contentAlignment = Alignment.Center) {
                Text(alphabetLabel(selected, koreanSyllables), color = PrismAccent.copy(alpha = .72f),
                    fontSize = (30f / density.fontScale.coerceAtLeast(1f)).sp, fontWeight = FontWeight.Normal)
            }
        }
        // This hit region never moves or grows with the visual wave. A held pointer may move left
        // outside it; its x position still pulls the visible alphabet away from the user's thumb.
        Box(Modifier.align(if (fromStart) Alignment.CenterStart else Alignment.CenterEnd).width(hitWidth).fillMaxHeight()
            .testTag(if (fromStart) "alphabet-rail-left" else "alphabet-rail").semantics { stateDescription = selected ?: "★" }
            .pointerInput(sections, density.density, railHeight, fromStart) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    down.consume()
                    var last = -1
                    fun select(position: Offset) {
                        fingerX = if (fromStart) railWidth.value - position.x / density.density
                            else railWidth.value - hitWidth.value + position.x / density.density
                        fingerY = (position.y / density.density).coerceIn(0f, railHeight.value)
                        val index = AlphabetWave.indexAt(position.y, size.height.toFloat(), sections.size)
                        if (last != index) {
                            last = index
                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        }
                        latestSelect(sections[index], railTop + position.y.coerceIn(0f, size.height.toFloat()),
                            AlphabetWave.positionAt(position.y, size.height.toFloat(), sections.size))
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
    state: LauncherState, section: String?, anchorY: Float, railPosition: Float, dragging: Boolean, onLaunch: (LauncherApp) -> Unit,
    onSelect: (LauncherApp) -> Unit, onSearch: () -> Unit,
    onSettings: () -> Unit, onRetry: () -> Unit,
) {
    val listState = rememberLazyListState()
    val latestSettings by rememberUpdatedState(onSettings)
    var listTop by remember { mutableFloatStateOf(0f) }
    val allGroups = remember(state.apps, state.showKoreanIndex) {
        val order = AppIndex.order(state.showKoreanIndex)
        state.apps.groupBy { AppIndex.section(it.label, it.englishLabel, state.showKoreanIndex) }
            .toList().sortedBy { order.indexOf(it.first) }.map { (letter, apps) ->
                letter to if (state.showKoreanIndex) apps else apps.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.englishLabel })
            }
    }
    val selectedOnly = state.selectedIndexOnly && section != null
    val groups = remember(allGroups, section, selectedOnly) {
        if (selectedOnly) listOf(section!! to (allGroups.firstOrNull { it.first == section }?.second ?: emptyList()))
        else allGroups
    }
    val sections = remember(state.apps, state.showAllIndexLetters, state.showKoreanIndex) {
        alphabetSections(state.apps.map { if (state.showKoreanIndex) it.label else it.englishLabel }, state.showAllIndexLetters, state.showKoreanIndex)
    }
    BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().testTag("alphabet-apps")) {
        val density = LocalDensity.current
        val viewportHeight = (maxHeight - 72.dp).coerceAtLeast(120.dp)
        val edgeSpace = viewportHeight
        // Fixed row metrics make the mapping continuous even across virtualized, unseen groups.
        val rowHeight = maxOf(58f, 22f * density.fontScale + 24f).dp
        val headerHeight = maxOf(34f, 20f * density.fontScale + 8f).dp
        val stops = remember(groups, sections, rowHeight, headerHeight) {
            var offset = 0f
            groups.map { (letter, apps) ->
                val stop = BrowseStop(sections.indexOf(letter).toFloat(), offset + headerHeight.value)
                offset += headerHeight.value + apps.size * rowHeight.value
                stop
            }
        }
        val itemOffsets = remember(groups, rowHeight, headerHeight) {
            buildList {
                var offset = 0f
                groups.forEach { (_, apps) ->
                    add(offset)
                    offset += headerHeight.value
                    apps.forEach { add(offset); offset += rowHeight.value }
                }
            }
        }
        val anchorPx = with(density) {
            val desired = if (anchorY > 0f) anchorY - listTop - rowHeight.toPx() * 2f else viewportHeight.toPx() * .45f
            desired.coerceIn(0f, (viewportHeight - rowHeight).coerceAtLeast(0.dp).toPx()).roundToInt()
        }
        LaunchedEffect(section, stops, anchorPx, railPosition, selectedOnly) {
            if (selectedOnly) {
                listState.scrollToItem(0)
            } else if (section != null && stops.isNotEmpty()) {
                val offset = interpolateBrowseOffset(stops, railPosition) - anchorPx / density.density
                val item = browseItemAt(itemOffsets, offset)
                val withinItem = with(density) { (offset - itemOffsets[item]).dp.toPx() }.roundToInt()
                listState.scrollToItem(item + 1, withinItem)
            }
        }
        Column(Modifier.fillMaxSize().padding(end = 64.dp, bottom = 72.dp).pointerInput(Unit) {
            detectTapGestures(onLongPress = { latestSettings() })
        }) {
            if (state.error) TextButton(onClick = onRetry) { Text(stringResource(R.string.retry)) }
            if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            LazyColumn(state = listState, modifier = Modifier.weight(1f).fillMaxWidth().onGloballyPositioned { listTop = it.positionInRoot().y }.testTag("alphabet-app-list"),
                contentPadding = PaddingValues(start = 40.dp, end = 8.dp, bottom = 24.dp)) {
                item("leading-space") { Spacer(Modifier.height(when {
                    selectedOnly -> (with(density) { anchorPx.toDp() } - headerHeight).coerceAtLeast(0.dp)
                    section == null -> 32.dp
                    else -> edgeSpace
                })) }
                groups.forEach { (letter, apps) ->
                    item("section:$letter") {
                        Text(alphabetLabel(letter, state.koreanIndexSyllables), Modifier.height(headerHeight).padding(start = 8.dp, top = 6.dp), color = Muted,
                            fontSize = 14.sp, fontWeight = FontWeight.Normal)
                    }
                    items(apps, key = LauncherApp::id) { app ->
                        AppRow(app, null, Modifier.height(rowHeight), large = true, onClick = { onLaunch(app) }, onLongClick = { onSelect(app) })
                    }
                    if (selectedOnly && apps.isEmpty()) item("empty-section") {
                        Text(stringResource(R.string.empty_index_section), Modifier.padding(start = 8.dp, top = 12.dp), color = Muted)
                    }
                }
                item("trailing-space") { Spacer(Modifier.height(if (selectedOnly) 24.dp else edgeSpace)) }
                if (!state.loading && state.apps.isEmpty()) item { Text(stringResource(R.string.empty_apps), color = Muted) }
            }
        }
        if (!dragging) IconButton(onClick = onSearch, modifier = Modifier.align(Alignment.BottomStart).padding(start = 40.dp, bottom = 16.dp)) {
            Icon(Icons.Rounded.Search, stringResource(R.string.search_apps), tint = Muted, modifier = Modifier.size(21.dp))
        }
    }
}
