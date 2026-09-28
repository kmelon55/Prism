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
import org.json.JSONArray
import org.json.JSONObject

/** Stack additions commit only after binding AND configuration succeed. */
class WidgetController(private val activity: ComponentActivity) {
    private val preferences = activity.getSharedPreferences("widgets", Context.MODE_PRIVATE)
    val manager: AppWidgetManager = AppWidgetManager.getInstance(activity)
    val host = AppWidgetHost(activity, 1701)
    private fun readStack(): WidgetStack = runCatching {
        if (!preferences.contains("stack")) {
            val legacy = preferences.getInt("active", AppWidgetManager.INVALID_APPWIDGET_ID)
            if (legacy == AppWidgetManager.INVALID_APPWIDGET_ID) WidgetStack()
            else WidgetStack(listOf(WidgetSlot(legacy, preferences.getInt("height", 180))), legacy)
        } else {
            val array = JSONArray(preferences.getString("stack", "[]"))
            val slots = List(array.length()) { index ->
                val item = array.getJSONObject(index)
                WidgetSlot(item.getInt("id"), item.optInt("height", 180).coerceIn(80, 480))
            }.filter { it.id != AppWidgetManager.INVALID_APPWIDGET_ID }.distinctBy { it.id }
            WidgetStack(slots, preferences.getInt("active", -1))
        }
    }.getOrDefault(WidgetStack())
    private val mutableStack = MutableStateFlow(readStack())
    val stack = mutableStack.asStateFlow()
    private val mutableId = MutableStateFlow(mutableStack.value.active?.id ?: AppWidgetManager.INVALID_APPWIDGET_ID)
    val activeId = mutableId.asStateFlow()
    private val mutableHeight = MutableStateFlow(mutableStack.value.active?.height ?: 180)
    val height = mutableHeight.asStateFlow()

    private fun save(next: WidgetStack, clearPending: Boolean = false) {
        val json = JSONArray().apply { next.slots.forEach { slot ->
            put(JSONObject().put("id", slot.id).put("height", slot.height))
        } }
        val edit = preferences.edit().putString("stack", json.toString())
            .putInt("active", next.active?.id ?: AppWidgetManager.INVALID_APPWIDGET_ID)
            .putInt("height", next.active?.height ?: 180)
        if (clearPending) edit.remove("pending")
        edit.apply()
        mutableStack.value = next
        mutableId.value = next.active?.id ?: AppWidgetManager.INVALID_APPWIDGET_ID
        mutableHeight.value = next.active?.height ?: 180
    }
    fun select(id: Int) = save(mutableStack.value.select(id))
    fun step(direction: Int) = save(mutableStack.value.step(direction))
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
        // Provider dimensions from AppWidgetManager are pixels; persist UI size in dp.
        val heightDp = (info.minHeight / activity.resources.displayMetrics.density).toInt().coerceIn(120, 400)
        save(mutableStack.value.add(WidgetSlot(id, heightDp)), clearPending = true)
    }

    fun cancelPending() {
        val id = pending
        if (id != AppWidgetManager.INVALID_APPWIDGET_ID && mutableStack.value.slots.none { it.id == id }) host.deleteAppWidgetId(id)
        preferences.edit().remove("pending").apply()
    }

    fun remove() {
        cancelPending()
        val id = mutableId.value
        save(mutableStack.value.remove(id))
        if (id != AppWidgetManager.INVALID_APPWIDGET_ID) host.deleteAppWidgetId(id)
    }

    fun resize(delta: Int) {
        val minHeight = manager.getAppWidgetInfo(mutableId.value)?.minHeight?.let {
            (it / activity.resources.displayMetrics.density).toInt()
        } ?: 80
        val next = (mutableHeight.value + delta).coerceIn(minHeight.coerceIn(80, 400), 480)
        save(mutableStack.value.resize(next))
    }

    companion object { const val CONFIGURE_REQUEST = 1702 }
}
