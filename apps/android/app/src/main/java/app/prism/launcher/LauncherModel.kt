package app.prism.launcher

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.pm.LauncherApps
import android.content.pm.LauncherActivityInfo
import android.content.res.Configuration
import android.os.Process
import android.os.UserHandle
import android.os.UserManager
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.text.Collator
import java.util.Locale

data class LauncherApp(val id: String, val label: String, val component: ComponentName, val user: UserHandle, val iconRevision: Int)
data class LauncherState(
    val apps: List<LauncherApp> = emptyList(),
    val favorites: List<String> = emptyList(),
    val aliases: Map<String, String> = emptyMap(),
    val recent: List<String> = emptyList(),
    val loading: Boolean = true,
    val error: Boolean = false,
)

class LauncherModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences("launcher", Context.MODE_PRIVATE)
    private val launcher = application.getSystemService(LauncherApps::class.java)
    private val users = application.getSystemService(UserManager::class.java)
    private val mutableState = MutableStateFlow(LauncherState(
        favorites = readList("favorites"), recent = readList("recent"), aliases = readAliases(),
    ))
    val state = mutableState.asStateFlow()
    private var refreshJob: Job? = null
    private var iconRevision = 0
    private var appLocale: Locale = application.resources.configuration.locales[0]
    private val callback = object : LauncherApps.Callback() {
        override fun onPackageAdded(packageName: String, user: UserHandle) = refresh()
        override fun onPackageRemoved(packageName: String, user: UserHandle) = refresh()
        override fun onPackageChanged(packageName: String, user: UserHandle) { iconRevision++; refresh() }
        override fun onPackagesAvailable(packageNames: Array<out String>, user: UserHandle, replacing: Boolean) = refresh()
        override fun onPackagesUnavailable(packageNames: Array<out String>, user: UserHandle, replacing: Boolean) = refresh()
    }

    init {
        launcher.registerCallback(callback)
        refresh()
    }

    private fun readList(name: String): List<String> = runCatching {
        val array = JSONArray(preferences.getString(name, "[]"))
        List(array.length()) { array.getString(it) }.distinct()
    }.getOrDefault(emptyList())

    private fun readAliases(): Map<String, String> = runCatching {
        val json = JSONObject(preferences.getString("aliases", "{}") ?: "{}")
        json.keys().asSequence().associateWith { json.getString(it) }
    }.getOrDefault(emptyMap())

    fun refresh() {
        val locale = appLocale
        refreshJob?.cancel()
        refreshJob = viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    // Personal profile for v0.1. Do not surface locked/private/work profiles accidentally.
                    val user = Process.myUserHandle()
                    val serial = users.getSerialNumberForUser(user)
                    val collator = Collator.getInstance(locale)
                    val localizedPackages = mutableMapOf<String, Context>()
                    val application = getApplication<Application>()
                    fun label(info: LauncherActivityInfo): String = runCatching {
                        val metadata = application.packageManager.getActivityInfo(info.componentName, 0)
                        metadata.nonLocalizedLabel?.toString() ?: run {
                            val labelResource = metadata.labelRes.takeIf { it != 0 }
                                ?: metadata.applicationInfo.labelRes
                            if (labelResource == 0) info.label.toString() else {
                                val packageContext = localizedPackages.getOrPut(info.componentName.packageName) {
                                    val base = application.createPackageContext(info.componentName.packageName, 0)
                                    base.createConfigurationContext(Configuration(base.resources.configuration).apply { setLocale(locale) })
                                }
                                packageContext.getString(labelResource)
                            }
                        }
                    }.getOrElse { info.label.toString() }
                    launcher.getActivityList(null, user)
                        .filter { it.componentName.packageName != getApplication<Application>().packageName }
                        .map { LauncherApp("$serial:${it.componentName.flattenToString()}", label(it), it.componentName, user, iconRevision) }
                        .sortedWith { left, right ->
                            val group = AppSearch.sectionOrder.indexOf(AppSearch.section(left.label))
                                .compareTo(AppSearch.sectionOrder.indexOf(AppSearch.section(right.label)))
                            if (group != 0) group else collator.compare(left.label, right.label)
                        }
                }
            }
            mutableState.value = mutableState.value.copy(
                apps = result.getOrDefault(mutableState.value.apps), loading = false, error = result.isFailure,
            )
        }
    }

    fun refreshForLocale(locale: Locale) {
        appLocale = locale
        refresh()
    }

    fun toggleFavorite(id: String) {
        val current = mutableState.value.favorites
        val next = if (id in current) current - id else current + id
        preferences.edit().putString("favorites", JSONArray(next).toString()).apply()
        mutableState.value = mutableState.value.copy(favorites = next)
    }

    fun moveFavorite(id: String, direction: Int) {
        val next = mutableState.value.favorites.toMutableList()
        val from = next.indexOf(id)
        val to = from + direction
        if (from < 0 || to !in next.indices) return
        next.add(to, next.removeAt(from))
        preferences.edit().putString("favorites", JSONArray(next).toString()).apply()
        mutableState.value = mutableState.value.copy(favorites = next)
    }

    fun rename(id: String, alias: String) {
        val next = mutableState.value.aliases.toMutableMap()
        if (alias.isBlank()) next.remove(id) else next[id] = alias.trim().take(60)
        preferences.edit().putString("aliases", JSONObject(next.toMap()).toString()).apply()
        mutableState.value = mutableState.value.copy(aliases = next)
    }

    fun launch(app: LauncherApp): Boolean = runCatching {
        launcher.startMainActivity(app.component, app.user, null, null)
        val next = (listOf(app.id) + mutableState.value.recent.filterNot { it == app.id }).take(12)
        preferences.edit().putString("recent", JSONArray(next).toString()).apply()
        mutableState.value = mutableState.value.copy(recent = next)
    }.onFailure { refresh() }.isSuccess

    override fun onCleared() {
        launcher.unregisterCallback(callback)
        super.onCleared()
    }
}
