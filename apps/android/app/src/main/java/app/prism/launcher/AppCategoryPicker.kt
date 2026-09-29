package app.prism.launcher

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
internal fun AppCategoryPicker(app: LauncherApp, override: String?, onChoose: (String?) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(onDismissRequest = onDismiss, title = { Text(stringResource(R.string.change_category)) },
        text = {
            LazyColumn(Modifier.testTag("category-picker")) {
                item {
                    Text(app.label, Modifier.padding(bottom = 12.dp), color = Muted)
                    CategoryChoice(stringResource(R.string.category_automatic,
                        stringResource((AppCategory.fromKey(app.category) ?: AppCategory.Other).title)), override == null,
                        "automatic") { onChoose(null) }
                }
                items(AppCategory.entries) { group ->
                    CategoryChoice(stringResource(group.title), override == group.key, group.key) { onChoose(group.key) }
                }
            }
        }, confirmButton = {}, dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun CategoryChoice(label: String, selected: Boolean, key: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth().testTag("category-choice-$key")) {
        Text(label, Modifier.weight(1f), color = Paper)
        if (selected) Icon(Icons.Rounded.Check, null, tint = PrismAccent)
    }
}
