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

internal val Ink = Color(0xFF111312)
internal val Paper = Color(0xFFF1F0EA)
internal val Muted = Color(0xFFA8ADA8)
private val Lilac = Color(0xFFD8E0D1)
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
    var browseSection by remember { mutableStateOf<String?>(null) }
    var railDragging by remember { mutableStateOf(false) }
    val railSections = remember(state.apps) { alphabetSections(state.apps.map { it.label }) }

    fun home() {
        screen = "home"; query = ""; searchFocused = false; browseSection = null
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
        surfaceContainer = Color(0xFF202420), outline = Color(0xFF646C64),
    )) {
        Surface(modifier = Modifier.fillMaxSize(), color = Color.Transparent, contentColor = Paper) {
        Box(Modifier.fillMaxSize().background(
            if (screen == "home") Brush.verticalGradient(listOf(Color(0xD9111312), Color(0xF2111312)))
            else Brush.verticalGradient(listOf(Ink, Ink)),
        )) {
            when (screen) {
                "home" -> HomeScreen(
                    state, activity.widgets, editingHome, launch,
                    onSearch = { browseSection = null; searchFocused = true; screen = "apps" },
                    onAllApps = { browseSection = null; searchFocused = false; screen = "apps" },
                    onSettings = { screen = "settings" },
                    onSelect = { selectedId = it.id },
                    onMove = model::moveFavorite,
                    onEdit = { editingHome = !editingHome },
                    onLock = activity::lockScreen,
                    defaultHome = defaultHome, onChooseHome = activity::chooseHome,
                )
                "apps" -> if (searchFocused) AppsScreen(state, query, { query = it }, true, launch,
                    onSelect = { selectedId = it.id }, onBack = ::home, onRetry = model::refresh)
                else AlphabetApps(state, browseSection, launch,
                    onSelect = { selectedId = it.id }, onBack = ::home,
                    onSearch = { searchFocused = true }, onSettings = { screen = "settings" }, onRetry = model::refresh)
                "settings" -> SettingsScreen(activity, onBack = ::home, onAddWidget = { widgetPicker = true },
                    onEditHome = { home(); editingHome = true })
            }
            // Keep this node mounted across home/browse transitions so a held pointer is never lost.
            if ((screen == "home" || screen == "apps") && !searchFocused && !editingHome) {
                AlphabetRail(railSections, browseSection, railDragging,
                    modifier = Modifier.align(Alignment.CenterEnd).safeDrawingPadding(),
                    onDragging = { railDragging = it },
                    onSection = { section ->
                        keyboard?.hide()
                        if (section == "★") home() else {
                            browseSection = section; query = ""; searchFocused = false; screen = "apps"
                        }
                    })
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
internal fun AppRow(app: LauncherApp, alias: String?, modifier: Modifier = Modifier, large: Boolean = false,
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

        }
    }
}

@Composable
internal fun HomeWidget(widgets: WidgetController) {
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
private fun SettingsScreen(activity: MainActivity, onBack: () -> Unit, onAddWidget: () -> Unit, onEditHome: () -> Unit) {
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
            TextButton(onClick = onEditHome) { Text(stringResource(R.string.edit_home)) }
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
