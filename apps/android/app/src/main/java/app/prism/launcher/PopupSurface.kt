@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)

package app.prism.launcher

import android.content.pm.ShortcutInfo
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Horizontal touch slop leaves vertical list scrolling and taps with their existing owners. */
internal fun Modifier.swipeRight(onOpen: () -> Unit): Modifier = swipeHorizontal(onRight = onOpen)

internal fun Modifier.swipeHorizontal(onLeft: (() -> Unit)? = null, onRight: () -> Unit): Modifier = composed {
    val currentOpen by rememberUpdatedState(onRight)
    val currentLeft by rememberUpdatedState(onLeft)
    val threshold = with(LocalDensity.current) { 56.dp.toPx() }
    pointerInput(threshold) {
        var distance = 0f
        detectHorizontalDragGestures(
            onDragStart = { distance = 0f },
            onDragCancel = { distance = 0f },
            onDragEnd = {
                if (distance >= threshold) currentOpen() else if (distance <= -threshold) currentLeft?.invoke()
                distance = 0f
            },
        ) { change, delta -> change.consume(); distance += delta }
    }
}

@Composable
internal fun AppShortcuts(app: LauncherApp, model: LauncherModel, defaultHome: Boolean,
    onChooseHome: () -> Unit, onLaunch: (ShortcutInfo) -> Unit) {
    val permission = model.hasShortcutPermission()
    val result by produceState<Result<List<ShortcutInfo>>?>(null, app.id, app.iconRevision, defaultHome, permission) {
        value = null
        if (permission) value = model.shortcuts(app)
    }
    Text(stringResource(R.string.app_shortcuts), color = Muted, style = MaterialTheme.typography.labelLarge)
    when {
        !permission -> TextButton(onClick = onChooseHome) { Text(stringResource(R.string.shortcuts_choose_home)) }
        result == null -> LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 12.dp))
        result!!.isFailure -> Text(stringResource(R.string.shortcuts_failed), color = Muted, modifier = Modifier.padding(vertical = 12.dp))
        result!!.getOrThrow().isEmpty() -> Text(stringResource(R.string.no_shortcuts), color = Muted, modifier = Modifier.padding(vertical = 12.dp))
        else -> result!!.getOrThrow().forEach { shortcut ->
            TextButton(onClick = { onLaunch(shortcut) }, modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(vertical = 12.dp)) {
                Icon(Icons.AutoMirrored.Rounded.OpenInNew, null, Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Text(shortcut.shortLabel?.toString().orEmpty(), Modifier.weight(1f), color = Paper)
            }
        }
    }
    HorizontalDivider(Modifier.padding(vertical = 12.dp))
}

@Composable
internal fun FolderRow(folder: LauncherFolder, modifier: Modifier = Modifier, onOpen: () -> Unit, onEdit: () -> Unit) {
    Row(modifier.fillMaxWidth().swipeRight(onOpen).combinedClickable(onClick = onOpen,
        onLongClick = onEdit, onLongClickLabel = stringResource(R.string.edit_folder))
        .padding(horizontal = 8.dp, vertical = 8.dp).testTag("folder-${folder.id}"),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(42.dp).prismPanel(LocalPrismEffects.current, 14.dp, luminous = false), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.FolderOpen, null, Modifier.size(23.dp), tint = PrismAccent)
        }
        Spacer(Modifier.width(24.dp))
        Text(folder.name, color = Paper, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
internal fun FolderPopup(folder: LauncherFolder, state: LauncherState, onDismiss: () -> Unit,
    onEdit: () -> Unit, onLaunch: (LauncherApp) -> Unit, onSelect: (LauncherApp) -> Unit) {
    val apps = folder.appIds.mapNotNull { id -> state.apps.find { it.id == id } }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface, tonalElevation = 0.dp, dragHandle = { PrismSheetHandle() }) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(folder.name, Modifier.weight(1f), style = MaterialTheme.typography.headlineSmall)
            IconButton(onClick = onEdit) { Icon(Icons.Rounded.Edit, stringResource(R.string.edit_folder)) }
        }
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = (LocalConfiguration.current.screenHeightDp * .55f).dp)
            .navigationBarsPadding().testTag("folder-popup"), contentPadding = PaddingValues(24.dp)) {
            if (apps.isEmpty()) item { Text(stringResource(R.string.empty_folder), color = Muted) }
            items(apps, key = LauncherApp::id) { app ->
                AppRow(app, state.aliases[app.id], onClick = { onLaunch(app) }, onLongClick = { onSelect(app) })
            }
        }
    }
}

@Composable
internal fun FolderEditor(folder: LauncherFolder?, apps: List<LauncherApp>, onDismiss: () -> Unit,
    onSave: (String, List<String>) -> Unit, onDelete: () -> Unit) {
    var name by rememberSaveable(folder?.id) { mutableStateOf(folder?.name.orEmpty()) }
    var selected by rememberSaveable(folder?.id) { mutableStateOf(ArrayList(folder?.appIds.orEmpty())) }
    var query by rememberSaveable(folder?.id) { mutableStateOf("") }
    var confirmDelete by rememberSaveable { mutableStateOf(false) }
    val matches = remember(apps, query) { apps.filter { query.isBlank() || AppSearch.score(SearchableApp(it.id, it.label, ""), query) != null } }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(stringResource(if (folder == null) R.string.create_folder else R.string.edit_folder)) },
        text = {
            Column {
                OutlinedTextField(name, { name = it.take(60) }, singleLine = true,
                    label = { Text(stringResource(R.string.folder_name)) }, modifier = Modifier.testTag("folder-name"))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(query, { query = it }, singleLine = true,
                    placeholder = { Text(stringResource(R.string.search_apps)) }, modifier = Modifier.testTag("folder-app-search"))
                LazyColumn(Modifier.fillMaxWidth().heightIn(max = (LocalConfiguration.current.screenHeightDp * .3f).dp)
                    .testTag("folder-app-picker")) {
                    items(matches, key = LauncherApp::id) { app ->
                        Row(Modifier.fillMaxWidth().toggleable(value = app.id in selected, role = Role.Checkbox, onValueChange = {
                            selected = ArrayList(if (app.id in selected) selected - app.id else selected + app.id)
                        }).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = app.id in selected, onCheckedChange = null)
                            Text(app.label, Modifier.padding(start = 8.dp).weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
                if (folder != null) TextButton(onClick = { confirmDelete = true }) { Text(stringResource(R.string.delete_folder), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = { TextButton(onClick = { onSave(name, selected) }, enabled = name.isNotBlank()) { Text(stringResource(R.string.save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } })
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false },
        title = { Text(stringResource(R.string.delete_folder)) }, text = { Text(stringResource(R.string.delete_folder_confirm)) },
        confirmButton = { TextButton(onClick = onDelete, modifier = Modifier.testTag("confirm-delete-folder")) { Text(stringResource(R.string.delete_folder)) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(R.string.cancel)) } })
}
