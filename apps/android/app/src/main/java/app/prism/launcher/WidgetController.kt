package app.prism.launcher

import android.app.Activity
import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.Context
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One home slot. A replacement commits only after binding AND configuration succeed. */
class WidgetController(private val activity: ComponentActivity) {
    private val preferences = activity.getSharedPreferences("widgets", Context.MODE_PRIVATE)
    val manager: AppWidgetManager = AppWidgetManager.getInstance(activity)
    val host = AppWidgetHost(activity, 1701)
    private val mutableId = MutableStateFlow(preferences.getInt("active", AppWidgetManager.INVALID_APPWIDGET_ID))
    val activeId = mutableId.asStateFlow()
    private val mutableHeight = MutableStateFlow(preferences.getInt("height", 180))
    val height = mutableHeight.asStateFlow()
    var onError: () -> Unit = {}
    private var pending: Int
        get() = preferences.getInt("pending", AppWidgetManager.INVALID_APPWIDGET_ID)
        set(value) { preferences.edit().putInt("pending", value).apply() }
    private val binding = activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val returnedId = result.data?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, pending) ?: pending
        if (returnedId == pending) {
            if (result.resultCode == Activity.RESULT_OK) configureOrCommit() else cancelPending()
        }
    }

    fun add(provider: AppWidgetProviderInfo) {
        cancelPending()
        pending = host.allocateAppWidgetId()
        runCatching {
            if (manager.bindAppWidgetIdIfAllowed(pending, provider.profile, provider.provider, null)) {
                configureOrCommit()
            } else {
                binding.launch(Intent(AppWidgetManager.ACTION_APPWIDGET_BIND).apply {
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, pending)
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER, provider.provider)
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER_PROFILE, provider.profile)
                })
            }
        }.onFailure { cancelPending(); onError() }
    }

    private fun configureOrCommit() {
        val id = pending
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
        val info = manager.getAppWidgetInfo(id)
        if (info == null) {
            cancelPending()
            onError()
        } else if (info.configure != null) {
            runCatching { host.startAppWidgetConfigureActivityForResult(activity, id, 0, CONFIGURE_REQUEST, null) }
                .onFailure { cancelPending(); onError() }
        } else commit()
    }

    fun configurationResult(resultCode: Int) {
        if (resultCode == Activity.RESULT_OK) commit() else cancelPending()
    }

    private fun commit() {
        val id = pending
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
        val info = manager.getAppWidgetInfo(id)
        if (info == null) { cancelPending(); onError(); return }
        val old = mutableId.value
        // Provider dimensions from AppWidgetManager are pixels; persist UI size in dp.
        val heightDp = (info.minHeight / activity.resources.displayMetrics.density).toInt().coerceIn(120, 400)
        preferences.edit().putInt("active", id).putInt("height", heightDp).remove("pending").apply()
        mutableId.value = id
        mutableHeight.value = heightDp
        if (old != AppWidgetManager.INVALID_APPWIDGET_ID && old != id) host.deleteAppWidgetId(old)
    }

    fun cancelPending() {
        val id = pending
        if (id != AppWidgetManager.INVALID_APPWIDGET_ID && id != mutableId.value) host.deleteAppWidgetId(id)
        preferences.edit().remove("pending").apply()
    }

    fun remove() {
        cancelPending()
        val id = mutableId.value
        preferences.edit().remove("active").apply()
        mutableId.value = AppWidgetManager.INVALID_APPWIDGET_ID
        if (id != AppWidgetManager.INVALID_APPWIDGET_ID) host.deleteAppWidgetId(id)
    }

    fun resize(delta: Int) {
        val minHeight = manager.getAppWidgetInfo(mutableId.value)?.minHeight?.let {
            (it / activity.resources.displayMetrics.density).toInt()
        } ?: 80
        val next = (mutableHeight.value + delta).coerceIn(minHeight.coerceIn(80, 400), 480)
        preferences.edit().putInt("height", next).apply()
        mutableHeight.value = next
    }

    companion object { const val CONFIGURE_REQUEST = 1702 }
}
