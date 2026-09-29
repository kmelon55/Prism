@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class, androidx.compose.material3.ExperimentalMaterial3Api::class)

package app.prism.launcher

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.pm.LauncherApps
import android.graphics.Bitmap
import android.graphics.drawable.AdaptiveIconDrawable
import android.os.Build
import android.util.LruCache
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    var folderId by rememberSaveable { mutableStateOf<String?>(null) }
    var editFolderId by rememberSaveable { mutableStateOf<String?>(null) }
    var folderEditor by rememberSaveable { mutableStateOf(false) }
    var aliasId by rememberSaveable { mutableStateOf<String?>(null) }
    var widgetPicker by rememberSaveable { mutableStateOf(false) }
    var editingHome by rememberSaveable { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    var browseSection by remember { mutableStateOf<String?>(null) }
    var railDragging by remember { mutableStateOf(false) }
    var railFromStart by remember { mutableStateOf(false) }
    var browseAnchor by remember { mutableFloatStateOf(0f) }
    var browsePosition by remember { mutableFloatStateOf(0f) }
    val railSections = remember(state.apps, state.showAllIndexLetters, state.showKoreanIndex) {
        alphabetSections(state.apps.map { if (state.showKoreanIndex) it.label else it.englishLabel }, state.showAllIndexLetters, state.showKoreanIndex)
    }

    fun home() {
        screen = "home"; query = ""; searchFocused = false; browseSection = null
        selectedId = null; folderId = null; folderEditor = false; editFolderId = null; aliasId = null; widgetPicker = false; editingHome = false
        keyboard?.hide()
    }
    // The initial composition should not erase state restored after widget binding/configuration.
    var lastHomeRequest by rememberSaveable { mutableIntStateOf(homeRequest) }
    LaunchedEffect(homeRequest) {
        if (homeRequest != lastHomeRequest) { home(); lastHomeRequest = homeRequest }
    }
    BackHandler(screen != "home" || editingHome) {
        home()
    }
    val launch: (LauncherApp) -> Unit = { app ->
        if (model.launch(app)) home() else activity.message(R.string.open_failed)
    }

    val appearance = PrismAppearance.resolve(state.prismEffects, state.prismMaterial, Build.VERSION.SDK_INT >= 33)
    PrismTheme(state.prismEffects, state.prismIcons, state.themeAccent,
        if (appearance == PrismAppearance.Liquid) state.glassWallpaperDim else state.wallpaperDim,
        appearance, state.glassBackgroundRevision) {
        Surface(modifier = Modifier.fillMaxSize(), color = Color.Transparent, contentColor = Paper) {
        Box(Modifier.fillMaxSize().glassViewport()) {
            PrismBackdrop(Modifier.matchParentSize())
            AnimatedContent(targetState = screen to searchFocused, modifier = Modifier.fillMaxSize(),
                transitionSpec = {
                    when {
                        targetState.first == "home" ->
                            (slideInVertically(tween(380, easing = FastOutSlowInEasing)) { -it / 3 } + fadeIn(tween(260))) togetherWith
                                (slideOutVertically(tween(300, easing = FastOutSlowInEasing)) { it / 5 } + fadeOut(tween(160)))
                        initialState.first == "home" && !railDragging ->
                            (slideInVertically(tween(320, easing = FastOutSlowInEasing)) { it / 5 } + fadeIn(tween(220))) togetherWith
                                (slideOutVertically(tween(280, easing = FastOutSlowInEasing)) { -it / 4 } + fadeOut(tween(160)))
                        else -> fadeIn(tween(140)) togetherWith fadeOut(tween(100))
                    }.using(null)
                }, label = "launcher-navigation") { route ->
            when (route.first) {
                "home" -> HomeScreen(
                    state, activity.widgets, editingHome, launch,
                    onSearch = { browseSection = null; searchFocused = true; screen = "apps" },
                    onChooseFavorites = { keyboard?.hide(); screen = "favorites" },
                    onSettings = { screen = "settings" },
                    onSelect = { keyboard?.hide(); selectedId = it.id },
                    onFolder = { folderId = it },
                    onEditFolder = { editFolderId = it; folderEditor = true },
                    onMoveFolder = model::moveFolder,
                    onMove = model::moveFavorite,
                    onEdit = { editingHome = !editingHome },
                    onLock = activity::lockScreen,
                    defaultHome = defaultHome, onChooseHome = activity::chooseHome,
                )
                "favorites" -> FavoritesPicker(state, model::toggleFavorite, onDone = ::home)
                "apps" -> if (route.second) PrismSearchScreen(state, query, { query = it }, launch,
                    onSelect = { keyboard?.hide(); selectedId = it.id }, onBack = ::home, onRetry = model::refresh,
                    onCommand = { command ->
                        keyboard?.hide()
                        when (command) {
                            PaletteCommand.Widgets -> widgetPicker = true
                            PaletteCommand.Settings -> screen = "settings"
                            PaletteCommand.ChooseFavorites -> screen = "favorites"
                            PaletteCommand.EditHome -> { home(); editingHome = true }
                            PaletteCommand.Wallpaper -> activity.chooseWallpaper()
                            PaletteCommand.AllApps -> { query = ""; browseSection = null; searchFocused = false }
                        }
                    })
                else AlphabetApps(state, browseSection, browseAnchor, browsePosition, railDragging, launch,
                    onSelect = { keyboard?.hide(); selectedId = it.id },
                    onSearch = { searchFocused = true }, onSettings = { screen = "settings" }, onRetry = model::refresh)
                "settings" -> SettingsScreen(activity, model, state, onBack = ::home, onAddWidget = { widgetPicker = true },
                    onEditHome = { home(); editingHome = true })
            }
            }
            // Keep this node mounted across home/browse transitions so a held pointer is never lost.
            if ((screen == "home" || screen == "apps") && !searchFocused && !editingHome) {
                for (fromStart in listOf(false, true)) {
                    AlphabetRail(railSections, browseSection, railDragging && railFromStart == fromStart,
                        modifier = Modifier.align(if (fromStart) Alignment.CenterStart else Alignment.CenterEnd).safeDrawingPadding(),
                        fromStart = fromStart, koreanSyllables = state.koreanIndexSyllables,
                        onDragging = { railDragging = it; if (it) railFromStart = fromStart },
                        onSection = { section, anchor, position ->
                            keyboard?.hide()
                            if (section == "★") home() else {
                                browseSection = section; browseAnchor = anchor; browsePosition = position
                                query = ""; searchFocused = false; screen = "apps"
                            }
                        })
                }
            }
        }
        }

        val selected = state.apps.find { it.id == selectedId }
        if (selected != null) {
            ModalBottomSheet(onDismissRequest = { selectedId = null },
                containerColor = MaterialTheme.colorScheme.surface, tonalElevation = 0.dp,
                dragHandle = { PrismSheetHandle() }) {
                Column(Modifier.heightIn(max = (LocalConfiguration.current.screenHeightDp * .7f).dp)
                    .verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).navigationBarsPadding()) {
                    Text(selected.label, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(bottom = 16.dp))
                    AppShortcuts(selected, model, defaultHome, activity::chooseHome) { shortcut ->
                        if (model.launchShortcut(shortcut)) home() else activity.message(R.string.open_failed)
                    }
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
        state.folders.find { it.id == folderId }?.let { folder ->
            FolderPopup(folder, state, onDismiss = { folderId = null },
                onEdit = { editFolderId = folder.id; folderId = null; folderEditor = true },
                onLaunch = launch, onSelect = { folderId = null; selectedId = it.id })
        }
        if (folderEditor) FolderEditor(state.folders.find { it.id == editFolderId }, state.apps,
            onDismiss = { folderEditor = false },
            onSave = { name, apps -> model.saveFolder(editFolderId, name, apps); folderEditor = false },
            onDelete = { editFolderId?.let(model::removeFolder); folderEditor = false })
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
    onClick: () -> Unit, onLongClick: () -> Unit, longClickLabel: String? = null) {
    Row(modifier.fillMaxWidth().swipeRight(onLongClick).clip(RoundedCornerShape(14.dp)).combinedClickable(
        onClick = onClick, onLongClick = onLongClick, onLongClickLabel = longClickLabel ?: stringResource(R.string.app_actions),
    ).padding(horizontal = 8.dp, vertical = if (large) 8.dp else 6.dp), verticalAlignment = Alignment.CenterVertically) {
        AppIcon(app)
        Spacer(Modifier.width(if (large) 24.dp else 18.dp))
        Column(Modifier.weight(1f)) {
            Text(app.label, color = Paper, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!alias.isNullOrBlank()) Text(alias, color = Muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
internal fun AppIcon(app: LauncherApp) {
    val context = LocalContext.current
    val themed = LocalPrismIcons.current
    val accent = if (PrismAccent == themeAccent("neutral")) prismIconAccent(app.id) else PrismAccent
    val iconColor = remember(themed, accent) {
        if (themed) ColorFilter.colorMatrix(ColorMatrix(floatArrayOf(
            .213f * accent.red, .715f * accent.red, .072f * accent.red, 0f, 0f,
            .213f * accent.green, .715f * accent.green, .072f * accent.green, 0f, 0f,
            .213f * accent.blue, .715f * accent.blue, .072f * accent.blue, 0f, 0f,
            0f, 0f, 0f, 1f, 0f,
        ))) else null
    }
    val cacheKey = "${app.id}:${app.iconRevision}:$themed"
    val bitmap by produceState<Bitmap?>(AppIcons.cache.get(cacheKey), cacheKey) {
        value = AppIcons.cache.get(cacheKey)
        if (value == null) value = withContext(Dispatchers.IO) {
            runCatching {
                val drawable = context.getSystemService(LauncherApps::class.java).getActivityList(app.component.packageName, app.user)
                    .find { it.componentName == app.component }?.getBadgedIcon(context.resources.displayMetrics.densityDpi)
                val mono = if (themed && Build.VERSION.SDK_INT >= 33) (drawable as? AdaptiveIconDrawable)?.monochrome else null
                val icon = mono?.mutate()?.apply { setTint(android.graphics.Color.WHITE) }
                    ?: if (themed && drawable is AdaptiveIconDrawable) drawable.foreground else drawable
                icon?.toBitmap(96, 96)?.also { AppIcons.cache.put(cacheKey, it) }
            }.getOrNull()
        }
    }
    val frame = if (themed) Modifier.prismPanel(LocalPrismEffects.current, 14.dp, luminous = false) else Modifier
    Box(Modifier.size(42.dp).then(frame), contentAlignment = Alignment.Center) {
        val rendered = bitmap
        if (rendered != null) Image(rendered.asImageBitmap(), null,
            Modifier.size(if (themed) 27.dp else 36.dp).clip(RoundedCornerShape(if (themed) 7.dp else 10.dp)),
            colorFilter = iconColor)
        else Text(app.label.take(1), color = if (themed) accent else PrismAccent, fontSize = 16.sp)
    }
}

@Composable
internal fun HomeWidget(widgets: WidgetController) {
    val stack by widgets.stack.collectAsStateWithLifecycle()
    PrismPanel(Modifier.fillMaxWidth()) {
        Box(Modifier.padding(16.dp)) {
            WidgetPager(stack, widgets::select) { slot -> HomeWidgetPage(widgets, slot) }
        }
    }
}

@Composable
private fun WidgetStackControls(widgets: WidgetController) {
    val stack by widgets.stack.collectAsStateWithLifecycle()
    Row(Modifier.fillMaxWidth().swipeHorizontal(onLeft = { widgets.step(1) }, onRight = { widgets.step(-1) }),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { widgets.step(-1) }) { Icon(Icons.Rounded.ChevronLeft, stringResource(R.string.previous_widget)) }
        Text(stringResource(R.string.widget_position, stack.slots.indexOf(stack.active) + 1, stack.slots.size), color = Muted)
        IconButton(onClick = { widgets.step(1) }) { Icon(Icons.Rounded.ChevronRight, stringResource(R.string.next_widget)) }
    }
}

@Composable
private fun HomeWidgetPage(widgets: WidgetController, slot: WidgetSlot) {
    val id = slot.id
    val height = slot.height
    if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
    val info = widgets.manager.getAppWidgetInfo(id)
    if (info == null) {
        Text(stringResource(R.string.widget_missing), color = Muted, modifier = Modifier.padding(vertical = 16.dp))
        return
    }
    key(id) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val width = maxWidth.value.toInt()
            AndroidView(
                factory = { context -> widgets.host.createView(context, id, info) },
                update = { view -> view.updateAppWidgetSize(null, width, height, width, height) },
                modifier = Modifier.fillMaxWidth().testTag("native-home-widget").height(height.dp).clip(RoundedCornerShape(18.dp)),
            )
        }
    }
}

@Composable
private fun SettingsScreen(activity: MainActivity, model: LauncherModel, state: LauncherState, onBack: () -> Unit, onAddWidget: () -> Unit, onEditHome: () -> Unit) {
    val appearance = LocalPrismAppearance.current
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
            PrismPanel(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SettingsLabel(R.string.prism_theme, R.string.prism_theme_hint)
                    Text(stringResource(R.string.surface_style), color = Muted)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(PrismAppearance.Flat to R.string.surface_flat, PrismAppearance.Matte to R.string.surface_matte,
                            PrismAppearance.Liquid to R.string.surface_liquid).forEach { (mode, label) ->
                            FilterChip(selected = appearance == mode, onClick = { model.setAppearance(mode) },
                                enabled = mode != PrismAppearance.Liquid || Build.VERSION.SDK_INT >= 33,
                                modifier = Modifier.testTag("appearance-${mode.key}"), label = { Text(stringResource(label)) })
                        }
                    }
                    if (Build.VERSION.SDK_INT < 33) Text(stringResource(R.string.glass_requires_android), color = Muted, style = MaterialTheme.typography.bodySmall)
                    Text(stringResource(R.string.icon_style), color = Muted)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(selected = !state.prismIcons, onClick = { model.setPrismIcons(false) },
                            modifier = Modifier.testTag("icons-original"), label = { Text(stringResource(R.string.icons_original)) })
                        FilterChip(selected = state.prismIcons, onClick = { model.setPrismIcons(true) },
                            modifier = Modifier.testTag("icons-themed"), label = { Text(stringResource(R.string.icons_themed)) })
                    }
                    if (appearance == PrismAppearance.Liquid) {
                        Text(stringResource(R.string.glass_hint), color = Muted, style = MaterialTheme.typography.bodySmall)
                        Text(stringResource(R.string.glass_background_hint), color = Muted, style = MaterialTheme.typography.bodySmall)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(onClick = activity::chooseGlassBackground, enabled = !state.glassBackgroundLoading,
                                modifier = Modifier.testTag("glass-choose-image")) { Text(stringResource(R.string.glass_choose_image)) }
                            TextButton(onClick = { model.setGlassBackground(null) }, enabled = !state.glassBackgroundLoading) {
                                Text(stringResource(R.string.glass_default_image))
                            }
                        }
                        if (state.glassBackgroundLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
                        if (state.glassBackgroundError) Text(stringResource(R.string.glass_image_error), color = MaterialTheme.colorScheme.error)
                    }
                    Text(stringResource(R.string.theme_accent), color = Muted)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("neutral" to R.string.accent_neutral, "blue" to R.string.accent_blue,
                            "sage" to R.string.accent_sage, "violet" to R.string.accent_violet).forEach { (value, label) ->
                            FilterChip(selected = state.themeAccent == value, onClick = { model.setThemeAccent(value) },
                                modifier = Modifier.testTag("theme-accent-$value"),
                                leadingIcon = { Box(Modifier.size(12.dp).background(themeAccent(value), androidx.compose.foundation.shape.CircleShape)) },
                                label = { Text(stringResource(label)) })
                        }
                    }
                    Text(stringResource(R.string.wallpaper_dim), color = Muted)
                    Slider(value = if (appearance == PrismAppearance.Liquid) state.glassWallpaperDim else state.wallpaperDim,
                        onValueChange = { if (appearance == PrismAppearance.Liquid) model.setGlassWallpaperDim(it) else model.setWallpaperDim(it) },
                        valueRange = if (appearance == PrismAppearance.Liquid) 0f.. .8f else .35f..1f,
                        modifier = Modifier.testTag("wallpaper-dim").semantics { contentDescription = activity.getString(R.string.wallpaper_dim) })
                    if (appearance != PrismAppearance.Liquid) TextButton(onClick = activity::chooseWallpaper) { Text(stringResource(R.string.choose_wallpaper)) }
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.show_clock), Modifier.weight(1f))
                        Switch(state.showClock, model::setShowClock, modifier = Modifier.testTag("show-clock"))
                    }

                }
            }
            SettingsLabel(R.string.default_launcher, if (isHome) R.string.default_active else R.string.default_launcher_hint)
            FilledTonalButton(onClick = activity::chooseHome) { Text(stringResource(R.string.choose_home)) }
            SettingsDivider()
            SettingsLabel(R.string.alphabet_settings, R.string.alphabet_settings_hint)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.alphabet_show_all), Modifier.weight(1f))
                Switch(checked = state.showAllIndexLetters, onCheckedChange = model::setShowAllIndexLetters,
                    modifier = Modifier.semantics { contentDescription = activity.getString(R.string.alphabet_show_all) })
            }
            Text(stringResource(R.string.korean_index_grouping), color = Muted, style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(selected = state.showKoreanIndex, onClick = { model.setShowKoreanIndex(true) },
                    label = { Text(stringResource(R.string.korean_index_separate)) })
                FilterChip(selected = !state.showKoreanIndex, onClick = { model.setShowKoreanIndex(false) },
                    label = { Text(stringResource(R.string.korean_index_english)) })
            }
            if (!state.showKoreanIndex) Text(stringResource(R.string.english_index_hint), color = Muted, style = MaterialTheme.typography.bodySmall)
            if (state.showKoreanIndex) {
                Text(stringResource(R.string.korean_index_style), color = Muted, style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = state.koreanIndexSyllables, onClick = { model.setKoreanIndexSyllables(true) },
                        label = { Text("가 · 나 · 다") })
                    FilterChip(selected = !state.koreanIndexSyllables, onClick = { model.setKoreanIndexSyllables(false) },
                        label = { Text("ㄱ · ㄴ · ㄷ") })
                }
            }
            Text(stringResource(R.string.index_browse_style), color = Muted, style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(selected = !state.selectedIndexOnly, onClick = { model.setSelectedIndexOnly(false) },
                    label = { Text(stringResource(R.string.index_browse_all)) })
                FilterChip(selected = state.selectedIndexOnly, onClick = { model.setSelectedIndexOnly(true) },
                    label = { Text(stringResource(R.string.index_browse_selected)) })
            }
            SettingsDivider()
            SettingsLabel(R.string.widgets, R.string.widget_hint)
            FilledTonalButton(onClick = onAddWidget) {
                Text(stringResource(R.string.add_widget))
            }
            if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                WidgetStackControls(activity.widgets)
                val label = activity.widgets.manager.getAppWidgetInfo(widgetId)?.loadLabel(activity.packageManager)
                Text(label ?: stringResource(R.string.widget_missing), color = Muted)
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
private fun SettingsDivider() { PrismRule(Modifier.padding(vertical = 12.dp)) }

@Composable
internal fun WidgetPicker(widgets: WidgetController, onDismiss: () -> Unit, onChoose: (AppWidgetProviderInfo) -> Unit) {
    val context = LocalContext.current
    val providers by produceState<List<Pair<AppWidgetProviderInfo, String>>?>(null) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                widgets.manager.getInstalledProvidersForProfile(android.os.Process.myUserHandle())
                    .filter { it.widgetCategory and AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN != 0 }
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
    var query by rememberSaveable { mutableStateOf("") }
    val matches = providers.orEmpty().filter { (provider, appLabel) ->
        query.isBlank() || "$appLabel ${provider.loadLabel(context.packageManager)}".contains(query, ignoreCase = true)
    }
    val pickerHeight = (LocalConfiguration.current.screenHeightDp * 0.55f).dp
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface, tonalElevation = 0.dp, dragHandle = { PrismSheetHandle() }) {
        Text(stringResource(R.string.widget_picker), style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(horizontal = 28.dp, vertical = 16.dp))
        OutlinedTextField(query, { query = it }, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).testTag("widget-search"),
            placeholder = { Text(stringResource(R.string.search_widgets)) }, leadingIcon = { Icon(Icons.Rounded.Search, null) })
        if (providers == null) LinearProgressIndicator(Modifier.fillMaxWidth())
        else if (providers!!.isEmpty()) Text(stringResource(R.string.no_widgets), modifier = Modifier.padding(28.dp))
        LazyColumn(Modifier.fillMaxWidth().height(pickerHeight).navigationBarsPadding().testTag("widget-picker"), contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)) {
            if (providers != null && providers!!.isNotEmpty() && matches.isEmpty()) item {
                Text(stringResource(R.string.empty_search), Modifier.padding(16.dp), color = Muted)
            }
            items(matches, key = { it.first.provider.flattenToString() }) { (provider, appLabel) ->
                TextButton(onClick = { onChoose(provider) }, modifier = Modifier.fillMaxWidth()
                    .testTag("widget-provider-${provider.provider.flattenToString()}"), contentPadding = PaddingValues(16.dp)) {
                    Column(Modifier.fillMaxWidth().prismPanel(LocalPrismEffects.current, 20.dp, false).padding(16.dp)) {
                        WidgetPreview(provider)
                        Text(provider.loadLabel(context.packageManager), color = Paper, style = MaterialTheme.typography.titleMedium)
                        Text(appLabel, color = Muted, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

@Composable
private fun WidgetPreview(provider: AppWidgetProviderInfo) {
    val context = LocalContext.current
    val preview by produceState<Bitmap?>(null, provider.provider) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                val drawable = provider.loadPreviewImage(context, context.resources.displayMetrics.densityDpi)
                    ?: provider.loadIcon(context, context.resources.displayMetrics.densityDpi)
                drawable?.let {
                    val width = it.intrinsicWidth.coerceIn(1, 720)
                    val height = it.intrinsicHeight.coerceIn(1, 480)
                    it.toBitmap(width, height)
                }
            }.getOrNull()
        }
    }
    val bitmap = preview
    if (bitmap != null) Image(bitmap.asImageBitmap(), null, Modifier.fillMaxWidth().height(112.dp).padding(bottom = 16.dp),
        contentScale = androidx.compose.ui.layout.ContentScale.Fit)
    else Icon(Icons.Rounded.Widgets, null, Modifier.size(48.dp).padding(bottom = 12.dp), tint = Muted)
}
