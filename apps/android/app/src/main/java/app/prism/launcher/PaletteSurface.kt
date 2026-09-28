package app.prism.launcher

import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal enum class PaletteCommand(val title: Int, val keywords: String, val icon: ImageVector) {
    Settings(R.string.settings, "settings 설정", Icons.Rounded.Tune),
    ChooseFavorites(R.string.add_favorites, "favorites add apps 즐겨찾기 추가 앱 선택", Icons.Rounded.Star),
    EditHome(R.string.edit_home, "edit favorites home 즐겨찾기 편집 홈", Icons.Rounded.StarOutline),
    Wallpaper(R.string.choose_wallpaper, "wallpaper background 배경화면", Icons.Rounded.Wallpaper),
    Widgets(R.string.add_widget, "widgets add 위젯 추가", Icons.Rounded.Widgets),
    AllApps(R.string.all_apps, "all apps 전체 앱 목록", Icons.Rounded.Apps),
}

@Composable
internal fun PrismSearchScreen(
    state: LauncherState, query: String, onQuery: (String) -> Unit,
    onLaunch: (LauncherApp) -> Unit, onSelect: (LauncherApp) -> Unit,
    onBack: () -> Unit, onRetry: () -> Unit,
    onCommand: (PaletteCommand) -> Unit,
) {
    val latestBack by rememberUpdatedState(onBack)
    val threshold = with(LocalDensity.current) { 56.dp.toPx() }
    val dismissScroll = remember(threshold) {
        object : NestedScrollConnection {
            var distance = 0f
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput) {
                    distance = if (available.y > 0) distance + available.y else 0f
                    if (distance > threshold) { distance = 0f; latestBack() }
                }
                return Offset.Zero
            }
            override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity { distance = 0f; return Velocity.Zero }
        }
    }
    val focusRequester = remember { FocusRequester() }
    val listState = rememberLazyListState()
    val keyboard = LocalSoftwareKeyboardController.current
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val apps = remember(state.apps, state.aliases, state.recent, state.favorites, query) {
        if (query.isBlank()) (state.recent + state.favorites).distinct().take(6).mapNotNull { id -> state.apps.find { it.id == id } }
        else state.apps.mapNotNull { app ->
            AppSearch.score(SearchableApp(app.id, app.label, state.aliases[app.id].orEmpty()), query)?.let { app to it }
        }.sortedWith(compareBy<Pair<LauncherApp, Int>> { it.second }.thenBy {
            state.recent.indexOf(it.first.id).takeIf { index -> index >= 0 } ?: Int.MAX_VALUE
        }).map { it.first }
    }
    val commands = remember(query, configuration) {
        PaletteCommand.entries.filter {
            query.isBlank() || AppSearch.score(SearchableApp(it.name, context.getString(it.title), it.keywords), query) != null
        }
    }
    fun submit() {
        if (query.isBlank()) return
        when {
            apps.isNotEmpty() -> onLaunch(apps.first())
            commands.isNotEmpty() -> onCommand(commands.first())
        }
    }
    LaunchedEffect(Unit) { focusRequester.requestFocus(); keyboard?.show() }
    LaunchedEffect(query) { listState.scrollToItem(0) }
    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().testTag("prism-search").nestedScroll(dismissScroll)) {
        Row(Modifier.fillMaxWidth().pointerInput(threshold) {
            var distance = 0f
            detectVerticalDragGestures(onDragStart = { distance = 0f }, onVerticalDrag = { change, delta ->
                distance = (distance + delta).coerceAtLeast(0f)
                if (distance > threshold) { change.consume(); distance = 0f; latestBack() }
            })
        }.padding(start = 8.dp, end = 16.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back))
            }
            OutlinedTextField(value = query, onValueChange = onQuery, singleLine = true,
                modifier = Modifier.weight(1f).prismPanel(LocalPrismEffects.current, 22.dp).focusRequester(focusRequester),
                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Color.Transparent, unfocusedBorderColor = Color.Transparent,
                    focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent, cursorColor = PrismAccent),
                placeholder = { Text(stringResource(R.string.prism_search_hint), fontSize = 14.sp) },
                trailingIcon = {
                    if (query.isNotEmpty()) IconButton(onClick = { onQuery("") }) {
                        Icon(Icons.Rounded.Close, stringResource(R.string.clear))
                    }
                },
                shape = RoundedCornerShape(22.dp), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { submit() }))
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("search-results"), state = listState, contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp)) {
            if (state.loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (state.error) item { TextButton(onClick = onRetry) { Text(stringResource(R.string.retry)) } }
            if (apps.isNotEmpty()) {
                item("apps-title") { PaletteLabel(stringResource(if (query.isBlank()) R.string.suggested_apps else R.string.search_apps)) }
                items(apps, key = { "app:${it.id}" }) { app ->
                    AppRow(app, state.aliases[app.id], onClick = { onLaunch(app) }, onLongClick = { onSelect(app) })
                }
            } else if (query.isNotBlank() && commands.isEmpty() && !state.loading) {
                item("empty") {
                    Text(stringResource(R.string.empty_search), Modifier.padding(8.dp), color = Muted, fontSize = 14.sp)
                }
            }
            if (commands.isNotEmpty()) {
                item("commands-title") { PaletteLabel(stringResource(R.string.commands)) }
                items(commands, key = { "command:${it.name}" }) { command ->
                    PaletteAction(stringResource(command.title), command.icon, { onCommand(command) },
                        Modifier.testTag("palette-command-${command.name}"))
                }
            }
        }
    }
}

@Composable
private fun PaletteLabel(label: String) {
    Text(label, Modifier.padding(start = 8.dp, top = 24.dp, bottom = 8.dp), color = Muted, fontSize = 12.sp)
}

@Composable
private fun PaletteAction(title: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier) {
    TextButton(onClick = onClick, modifier = modifier.fillMaxWidth().heightIn(min = 52.dp), contentPadding = PaddingValues(8.dp)) {
        Box(Modifier.size(38.dp).prismPanel(LocalPrismEffects.current, 12.dp, luminous = false), contentAlignment = Alignment.Center) {
            Icon(icon, null, Modifier.size(19.dp), tint = PrismAccent)
        }
        Spacer(Modifier.width(20.dp))
        Text(title, Modifier.weight(1f), color = Paper, fontSize = 15.sp)
    }
}


@Composable
internal fun FavoritesPicker(state: LauncherState, onToggle: (String) -> Unit, onDone: () -> Unit) {
    var query by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf("") }
    val apps = remember(state.apps, state.aliases, query) {
        state.apps.filter { query.isBlank() || AppSearch.score(SearchableApp(it.id, it.label, state.aliases[it.id].orEmpty()), query) != null }
    }
    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().testTag("favorites-picker")) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onDone) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back)) }
            Text(stringResource(R.string.favorites), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
            TextButton(onClick = onDone, modifier = Modifier.testTag("favorites-done")) { Text(stringResource(R.string.done)) }
        }
        OutlinedTextField(query, { query = it }, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            placeholder = { Text(stringResource(R.string.search_apps)) },
            leadingIcon = { Icon(Icons.Rounded.Search, null) }, shape = RoundedCornerShape(22.dp))
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp)) {
            if (state.loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (apps.isEmpty() && !state.loading) item {
                Text(stringResource(R.string.empty_search), Modifier.padding(16.dp), color = Muted)
            }
            items(apps, key = LauncherApp::id) { app ->
                val favorite = app.id in state.favorites
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    AppRow(app, state.aliases[app.id], Modifier.weight(1f).testTag("favorite-picker-${app.id}"),
                        onClick = { onToggle(app.id) }, onLongClick = { onToggle(app.id) },
                        longClickLabel = stringResource(if (favorite) R.string.remove_favorite else R.string.add_favorite))
                    IconToggleButton(checked = favorite, onCheckedChange = { onToggle(app.id) },
                        modifier = Modifier.testTag("favorite-toggle-${app.id}")) {
                        Icon(if (favorite) Icons.Rounded.Star else Icons.Rounded.StarOutline,
                            stringResource(if (favorite) R.string.remove_favorite else R.string.add_favorite),
                            tint = if (favorite) PrismAccent else Muted)
                    }
                }
            }
        }
    }
}
