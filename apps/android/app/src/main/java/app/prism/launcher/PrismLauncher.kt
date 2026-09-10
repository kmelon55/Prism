@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class, androidx.compose.material3.ExperimentalMaterial3Api::class)

package app.prism.launcher

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.pm.LauncherApps
import android.graphics.Bitmap
import android.util.LruCache
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

private val Ink = Color(0xFF15131C)
private val Paper = Color(0xFFF4F0FA)
private val Muted = Color(0xFFB8B1C6)
private val Lilac = Color(0xFFD0C1FF)
internal object AppIcons { val cache = LruCache<String, Bitmap>(100) }

@Composable
fun PrismLauncher(model: LauncherModel, activity: MainActivity) {
    val state by model.state.collectAsStateWithLifecycle()
    val homeRequest by activity.homeRequest.collectAsStateWithLifecycle()
    val defaultHome by activity.defaultHome.collectAsStateWithLifecycle()
    var screen by rememberSaveable { mutableStateOf("home") }
    var query by rememberSaveable { mutableStateOf("") }
    var searchFocused by rememberSaveable { mutableStateOf(false) }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var aliasId by rememberSaveable { mutableStateOf<String?>(null) }
    var widgetPicker by rememberSaveable { mutableStateOf(false) }
    var editingHome by rememberSaveable { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current

    fun home() {
        screen = "home"; query = ""; searchFocused = false
        selectedId = null; aliasId = null; widgetPicker = false; editingHome = false
        keyboard?.hide()
    }
    // The initial composition should not erase state restored after widget binding/configuration.
    var lastHomeRequest by rememberSaveable { mutableIntStateOf(homeRequest) }
    LaunchedEffect(homeRequest) {
        if (homeRequest != lastHomeRequest) { home(); lastHomeRequest = homeRequest }
    }
    BackHandler(screen != "home" || editingHome) { home() }
    val launch: (LauncherApp) -> Unit = { app ->
        if (model.launch(app)) home() else activity.message(R.string.open_failed)
    }

    MaterialTheme(colorScheme = darkColorScheme(
        primary = Lilac, onPrimary = Ink, background = Ink, surface = Ink,
        onSurface = Paper, onBackground = Paper, onSurfaceVariant = Muted,
        surfaceContainer = Color(0xFF23202E), outline = Color(0xFF655F72),
    )) {
        Surface(modifier = Modifier.fillMaxSize(), color = Color.Transparent, contentColor = Paper) {
        Box(Modifier.fillMaxSize().background(
            if (screen == "home") Brush.verticalGradient(listOf(Color(0xB51A1525), Color(0xD9101018)))
            else Brush.verticalGradient(listOf(Ink, Ink)),
        )) {
            when (screen) {
                "home" -> HomeScreen(
                    state, activity.widgets, editingHome, launch,
                    onSearch = { searchFocused = true; screen = "apps" },
                    onAllApps = { searchFocused = false; screen = "apps" },
                    onSettings = { screen = "settings" },
                    onSelect = { selectedId = it.id },
                    onMove = model::moveFavorite,
                    onEdit = { editingHome = !editingHome },
                    onLock = activity::lockScreen,
                    defaultHome = defaultHome, onChooseHome = activity::chooseHome,
                )
                "apps" -> AppsScreen(state, query, { query = it }, searchFocused, launch,
                    onSelect = { selectedId = it.id }, onBack = ::home, onRetry = model::refresh)
                "settings" -> SettingsScreen(activity, onBack = ::home, onAddWidget = { widgetPicker = true })
            }
        }
        }

        val selected = state.apps.find { it.id == selectedId }
        if (selected != null) {
            ModalBottomSheet(onDismissRequest = { selectedId = null }) {
                Column(Modifier.padding(horizontal = 24.dp).navigationBarsPadding()) {
                    Text(selected.label, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(bottom = 16.dp))
                    val favorite = selected.id in state.favorites
                    TextButton(onClick = { model.toggleFavorite(selected.id); selectedId = null }) {
                        Icon(if (favorite) Icons.Rounded.StarOutline else Icons.Rounded.Star, null)
                        Spacer(Modifier.width(12.dp))
                        Text(stringResource(if (favorite) R.string.remove_favorite else R.string.add_favorite))
                    }
                    TextButton(onClick = { aliasId = selected.id; selectedId = null }) {
                        Icon(Icons.Rounded.Edit, null); Spacer(Modifier.width(12.dp)); Text(stringResource(R.string.edit_alias))
                    }
                    TextButton(onClick = { activity.appInfo(selected); selectedId = null }) {
                        Icon(Icons.Rounded.Info, null); Spacer(Modifier.width(12.dp)); Text(stringResource(R.string.app_info))
                    }
                    Spacer(Modifier.height(24.dp))
                }
            }
        }
        aliasId?.let { id ->
            var alias by rememberSaveable(id) { mutableStateOf(state.aliases[id] ?: "") }
            AlertDialog(
                onDismissRequest = { aliasId = null }, title = { Text(stringResource(R.string.edit_alias)) },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedTextField(value = alias, onValueChange = { alias = it.take(60) }, singleLine = true,
                            label = { Text(stringResource(R.string.alias)) })
                        Text(stringResource(R.string.alias_hint), style = MaterialTheme.typography.bodySmall)
                    }
                },
                confirmButton = { TextButton(onClick = { model.rename(id, alias); aliasId = null }) { Text(stringResource(R.string.save)) } },
                dismissButton = { TextButton(onClick = { aliasId = null }) { Text(stringResource(R.string.cancel)) } },
            )
        }
        if (widgetPicker) WidgetPicker(activity.widgets, onDismiss = { widgetPicker = false }) { provider ->
            widgetPicker = false
            activity.widgets.add(provider)
        }
    }
}

@Composable
private fun HomeScreen(
    state: LauncherState, widgets: WidgetController, editing: Boolean,
    onLaunch: (LauncherApp) -> Unit, onSearch: () -> Unit, onAllApps: () -> Unit,
    onSettings: () -> Unit, onSelect: (LauncherApp) -> Unit,
    onMove: (String, Int) -> Unit, onEdit: () -> Unit, onLock: () -> Unit,
    defaultHome: Boolean, onChooseHome: () -> Unit,
) {
    val favoriteApps = remember(state.apps, state.favorites) {
        val byId = state.apps.associateBy(LauncherApp::id)
        state.favorites.mapNotNull(byId::get)
    }
    val threshold = with(LocalDensity.current) { 64.dp.toPx() }
    val latestSearch by rememberUpdatedState(onSearch)
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
    Column(Modifier.fillMaxSize().safeDrawingPadding().nestedScroll(searchScroll)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("PRISM", fontSize = 11.sp, letterSpacing = 3.sp, color = Muted, modifier = Modifier.weight(1f))
            if (favoriteApps.isNotEmpty()) IconButton(onClick = onEdit) {
                Icon(if (editing) Icons.Rounded.Check else Icons.Rounded.Edit,
                    stringResource(if (editing) R.string.done else R.string.edit_home), tint = Muted, modifier = Modifier.size(19.dp))
            }
            IconButton(onClick = onSettings) {
                Icon(Icons.Rounded.Tune, stringResource(R.string.settings), tint = Muted, modifier = Modifier.size(21.dp))
            }
        }
        LazyColumn(
            modifier = Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(horizontal = 28.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (!defaultHome) item("default-home") {
                TextButton(onClick = onChooseHome) { Text(stringResource(R.string.choose_home)) }
            }
            item("clock") {
                Box(Modifier.fillMaxWidth().pointerInput(threshold) {
                    var distance = 0f
                    detectVerticalDragGestures(onDragStart = { distance = 0f },
                        onDragEnd = { if (distance < -threshold) latestSearch() },
                        onVerticalDrag = { change, amount -> change.consume(); distance += amount })
                }.pointerInput(Unit) { detectTapGestures(onDoubleTap = { latestLock() }) }) { HomeClock() }
            }
            item("widget") { HomeWidget(widgets) }
            if (state.loading && favoriteApps.isEmpty()) item { Text(stringResource(R.string.loading), color = Muted) }
            if (!state.loading && favoriteApps.isEmpty()) item {
                Column(Modifier.fillMaxWidth().padding(top = 40.dp, bottom = 56.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.empty_home), style = MaterialTheme.typography.headlineSmall, color = Paper)
                    Text(stringResource(R.string.empty_home_hint), color = Muted, style = MaterialTheme.typography.bodyMedium)
                    TextButton(onClick = onAllApps) { Text(stringResource(R.string.all_apps)) }
                }
            }
            items(favoriteApps, key = LauncherApp::id) { app ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    AppRow(app, state.aliases[app.id], Modifier.weight(1f), large = true,
                        onClick = { if (editing) onSelect(app) else onLaunch(app) }, onLongClick = { onSelect(app) })
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
        Column(
            Modifier.fillMaxWidth().pointerInput(threshold) {
                var distance = 0f
                detectVerticalDragGestures(onDragStart = { distance = 0f },
                    onDragEnd = { if (distance < -threshold) latestSearch() },
                    onVerticalDrag = { change, amount -> change.consume(); distance += amount })
            }.pointerInput(Unit) { detectTapGestures(onDoubleTap = { latestLock() }) }.padding(horizontal = 28.dp, vertical = 16.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onSearch) {
                    Icon(Icons.Rounded.Search, null); Spacer(Modifier.width(10.dp)); Text(stringResource(R.string.search_apps))
                }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onAllApps) { Icon(Icons.Rounded.Apps, stringResource(R.string.all_apps), tint = Muted) }
            }
            Text(stringResource(R.string.swipe_hint), color = Muted, fontSize = 11.sp, modifier = Modifier.padding(start = 12.dp, top = 4.dp))
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
    val pattern = if (android.text.format.DateFormat.is24HourFormat(context)) "HH:mm" else "h:mm"
    val locale = LocalConfiguration.current.locales[0]
    Column(Modifier.padding(top = 28.dp, bottom = 30.dp)) {
        Text(now.format(DateTimeFormatter.ofPattern(pattern)), fontSize = 64.sp, fontWeight = FontWeight.Light, letterSpacing = (-2).sp, color = Paper)
        val datePattern = android.text.format.DateFormat.getBestDateTimePattern(locale, "MMMEd")
        Text(now.format(DateTimeFormatter.ofPattern(datePattern, locale)), color = Muted, fontSize = 15.sp)
    }
}

@Composable
private fun AppRow(app: LauncherApp, alias: String?, modifier: Modifier = Modifier, large: Boolean = false,
    onClick: () -> Unit, onLongClick: () -> Unit) {
    Row(modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).combinedClickable(
        onClick = onClick, onLongClick = onLongClick, onLongClickLabel = stringResource(R.string.app_info),
    ).padding(horizontal = 8.dp, vertical = if (large) 12.dp else 9.dp), verticalAlignment = Alignment.CenterVertically) {
        AppIcon(app)
        Spacer(Modifier.width(18.dp))
        Column(Modifier.weight(1f)) {
            Text(app.label, color = Paper, fontSize = if (large) 23.sp else 18.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!alias.isNullOrBlank()) Text(alias, color = Muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun AppIcon(app: LauncherApp) {
    val context = LocalContext.current
    val cacheKey = "${app.id}:${app.iconRevision}"
    val bitmap by produceState<Bitmap?>(AppIcons.cache.get(cacheKey), cacheKey) {
        value = AppIcons.cache.get(cacheKey)
        if (value == null) value = withContext(Dispatchers.IO) {
            runCatching {
                context.getSystemService(LauncherApps::class.java).getActivityList(app.component.packageName, app.user)
                    .find { it.componentName == app.component }?.getBadgedIcon(context.resources.displayMetrics.densityDpi)
                    ?.toBitmap(96, 96)?.also { AppIcons.cache.put(cacheKey, it) }
            }.getOrNull()
        }
    }
    val rendered = bitmap
    if (rendered != null) Image(rendered.asImageBitmap(), null, Modifier.size(36.dp))
    else Box(Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(Color(0xFF373143)), contentAlignment = Alignment.Center) {
        Text(app.label.take(1), color = Lilac, fontSize = 16.sp)
    }
}

@Composable
private fun AppsScreen(state: LauncherState, query: String, onQuery: (String) -> Unit, focus: Boolean,
    onLaunch: (LauncherApp) -> Unit, onSelect: (LauncherApp) -> Unit, onBack: () -> Unit, onRetry: () -> Unit) {
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val apps = remember(state.apps, state.aliases, state.recent, query) {
        if (query.isBlank()) state.apps else state.apps.mapNotNull { app ->
            AppSearch.score(SearchableApp(app.id, app.label, state.aliases[app.id] ?: ""), query)?.let { app to it }
        }.sortedWith(compareBy<Pair<LauncherApp, Int>> { it.second }.thenBy {
            state.recent.indexOf(it.first.id).takeIf { index -> index >= 0 } ?: Int.MAX_VALUE
        }).map { it.first }
    }
    LaunchedEffect(focus) {
        if (focus) { focusRequester.requestFocus(); keyboard?.show() }
    }
    LaunchedEffect(query) { listState.scrollToItem(0) }
    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 20.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back)) }
            Text(stringResource(R.string.all_apps), style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            Text(apps.size.toString(), color = Muted, style = MaterialTheme.typography.labelMedium)
        }
        OutlinedTextField(
            value = query, onValueChange = onQuery, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp).focusRequester(focusRequester),
            placeholder = { Text(stringResource(R.string.search_hint), fontSize = 14.sp) },
            leadingIcon = { Icon(Icons.Rounded.Search, stringResource(R.string.search_apps)) },
            trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { onQuery("") }) { Icon(Icons.Rounded.Close, stringResource(R.string.clear)) } },
            shape = RoundedCornerShape(20.dp), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { if (query.isNotBlank()) apps.firstOrNull()?.let(onLaunch) }),
        )
        if (state.error) Row(Modifier.padding(horizontal = 24.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.catalog_error), Modifier.weight(1f), color = Muted)
            TextButton(onClick = onRetry) { Text(stringResource(R.string.retry)) }
        }
        if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (apps.isEmpty() && !state.loading) {
            Column(Modifier.padding(28.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(if (query.isBlank()) R.string.empty_apps else R.string.empty_search), style = MaterialTheme.typography.titleMedium)
                if (query.isNotBlank()) Text(stringResource(R.string.empty_search_hint), color = Muted)
            }
        }
        // A separate recent row only in search mode. Keep alphabet positions based on the actual list.
        if (query.isBlank() && focus && state.recent.isNotEmpty()) {
            Text(stringResource(R.string.recent_apps), color = Muted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 28.dp, vertical = 4.dp))
            val recent = state.recent.take(3).mapNotNull { id -> state.apps.find { it.id == id } }
            recent.forEach { app -> AppRow(app, null, Modifier.padding(horizontal = 20.dp), onClick = { onLaunch(app) }, onLongClick = { onSelect(app) }) }
            HorizontalDivider(Modifier.padding(horizontal = 28.dp, vertical = 8.dp), color = Color(0xFF332E40))
        }
        Row(Modifier.weight(1f)) {
            LazyColumn(state = listState, modifier = Modifier.weight(1f), contentPadding = PaddingValues(start = 20.dp, end = 4.dp, bottom = 20.dp)) {
                items(apps, key = LauncherApp::id) { app ->
                    AppRow(app, state.aliases[app.id], onClick = { onLaunch(app) }, onLongClick = { onSelect(app) })
                }
            }
            if (query.isBlank()) {
                val sections = remember(apps) { apps.map { AppSearch.section(it.label) }.distinct() }
                Column(Modifier.width(48.dp).fillMaxHeight().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
                    sections.forEach { section ->
                        TextButton(onClick = {
                            keyboard?.hide()
                            val index = apps.indexOfFirst { AppSearch.section(it.label) == section }
                            if (index >= 0) scope.launch { listState.scrollToItem(index) }
                        }, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp), contentPadding = PaddingValues(0.dp)) {
                            Text(section, fontSize = 12.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HomeWidget(widgets: WidgetController) {
    val id by widgets.activeId.collectAsStateWithLifecycle()
    val height by widgets.height.collectAsStateWithLifecycle()
    if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
    val info = widgets.manager.getAppWidgetInfo(id)
    if (info == null) {
        Text(stringResource(R.string.widget_missing), color = Muted, modifier = Modifier.padding(vertical = 16.dp))
        return
    }
    key(id) {
        BoxWithConstraints(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            val width = maxWidth.value.toInt()
            AndroidView(
                factory = { context -> widgets.host.createView(context, id, info) },
                update = { view -> view.updateAppWidgetSize(null, width, height, width, height) },
                modifier = Modifier.fillMaxWidth().height(height.dp),
            )
        }
    }
}

@Composable
private fun SettingsScreen(activity: MainActivity, onBack: () -> Unit, onAddWidget: () -> Unit) {
    val isHome by activity.defaultHome.collectAsStateWithLifecycle()
    val widgetId by activity.widgets.activeId.collectAsStateWithLifecycle()
    val lockRequested by activity.lockRequested.collectAsStateWithLifecycle()
    val lockConnected by ScreenLockService.connected.collectAsStateWithLifecycle()
    var confirmRemove by rememberSaveable { mutableStateOf(false) }
    var explainLock by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back)) }
            Text(stringResource(R.string.settings), style = MaterialTheme.typography.titleLarge)
        }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 28.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SettingsLabel(R.string.default_launcher, if (isHome) R.string.default_active else R.string.default_launcher_hint)
            FilledTonalButton(onClick = activity::chooseHome) { Text(stringResource(R.string.choose_home)) }
            SettingsDivider()
            SettingsLabel(R.string.widgets, R.string.widget_hint)
            FilledTonalButton(onClick = onAddWidget) {
                Text(stringResource(if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) R.string.add_widget else R.string.replace_widget))
            }
            if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { activity.widgets.resize(-40) }) { Icon(Icons.Rounded.Remove, stringResource(R.string.widget_shorter)) }
                    IconButton(onClick = { activity.widgets.resize(40) }) { Icon(Icons.Rounded.Add, stringResource(R.string.widget_taller)) }
                    TextButton(onClick = { confirmRemove = true }) { Text(stringResource(R.string.remove_widget)) }
                }
            }
            SettingsDivider()
            SettingsLabel(R.string.appearance, R.string.wallpaper_hint)
            FilledTonalButton(onClick = activity::chooseWallpaper) { Text(stringResource(R.string.choose_wallpaper)) }
            SettingsDivider()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    SettingsLabel(R.string.screen_lock, R.string.screen_lock_hint)
                }
                Spacer(Modifier.width(12.dp))
                Switch(checked = lockRequested, onCheckedChange = {
                    if (it) explainLock = true else activity.setScreenLock(false)
                })
            }
            if (lockRequested && !lockConnected) TextButton(onClick = { explainLock = true }) {
                Text(stringResource(R.string.screen_lock_permission))
            }
            SettingsDivider()
            Text(stringResource(R.string.about), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.local_only), style = MaterialTheme.typography.bodyMedium, color = Muted)
            Spacer(Modifier.height(36.dp))
        }
    }
    if (confirmRemove) AlertDialog(onDismissRequest = { confirmRemove = false },
        title = { Text(stringResource(R.string.remove_widget)) }, text = { Text(stringResource(R.string.remove_widget_confirm)) },
        confirmButton = { TextButton(onClick = { activity.widgets.remove(); confirmRemove = false }) { Text(stringResource(R.string.remove_widget)) } },
        dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text(stringResource(R.string.cancel)) } })
    if (explainLock) AlertDialog(onDismissRequest = { explainLock = false },
        title = { Text(stringResource(R.string.screen_lock)) }, text = { Text(stringResource(R.string.screen_lock_disclosure)) },
        confirmButton = { TextButton(onClick = { explainLock = false; activity.setScreenLock(true) }) { Text(stringResource(R.string.open_accessibility)) } },
        dismissButton = { TextButton(onClick = { explainLock = false }) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun SettingsLabel(title: Int, description: Int) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(description), style = MaterialTheme.typography.bodyMedium, color = Muted)
    }
}

@Composable
private fun SettingsDivider() { HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color(0xFF332E40)) }

@Composable
private fun WidgetPicker(widgets: WidgetController, onDismiss: () -> Unit, onChoose: (AppWidgetProviderInfo) -> Unit) {
    val context = LocalContext.current
    val providers by produceState<List<Pair<AppWidgetProviderInfo, String>>?>(null) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                widgets.manager.getInstalledProvidersForProfile(android.os.Process.myUserHandle())
                    .sortedBy { it.loadLabel(context.packageManager) }.map { provider ->
                        val appLabel = runCatching {
                            context.packageManager.getApplicationInfo(provider.provider.packageName, 0).loadLabel(context.packageManager).toString()
                        }.getOrDefault(provider.loadLabel(context.packageManager))
                        provider to appLabel
                    }
            }
                .getOrDefault(emptyList())
        }
    }
    val pickerHeight = (LocalConfiguration.current.screenHeightDp * 0.55f).dp
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Text(stringResource(R.string.widget_picker), style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(horizontal = 28.dp, vertical = 16.dp))
        if (providers == null) LinearProgressIndicator(Modifier.fillMaxWidth())
        else if (providers!!.isEmpty()) Text(stringResource(R.string.no_widgets), modifier = Modifier.padding(28.dp))
        LazyColumn(Modifier.fillMaxWidth().height(pickerHeight).navigationBarsPadding(), contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)) {
            items(providers.orEmpty(), key = { it.first.provider.flattenToString() }) { (provider, appLabel) ->
                TextButton(onClick = { onChoose(provider) }, modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
                    Column(Modifier.fillMaxWidth()) {
                        Text(provider.loadLabel(context.packageManager), color = Paper, style = MaterialTheme.typography.titleMedium)
                        Text(appLabel, color = Muted, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}
