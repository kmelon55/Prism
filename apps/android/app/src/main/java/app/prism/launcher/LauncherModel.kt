package app.prism.launcher

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.pm.LauncherApps
import android.content.pm.LauncherActivityInfo
import android.content.pm.ShortcutInfo
import java.util.UUID
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

data class LauncherApp(val id: String, val label: String, val component: ComponentName, val user: UserHandle, val iconRevision: Int, val englishLabel: String = label)
data class LauncherFolder(val id: String, val name: String, val appIds: List<String>)

data class LauncherState(
    val apps: List<LauncherApp> = emptyList(),
    val favorites: List<String> = emptyList(),
    val folders: List<LauncherFolder> = emptyList(),
    val aliases: Map<String, String> = emptyMap(),
    val recent: List<String> = emptyList(),
    val showAllIndexLetters: Boolean = true,
    val koreanIndexSyllables: Boolean = true,
    val showKoreanIndex: Boolean = true,
    val selectedIndexOnly: Boolean = false,
    val themeAccent: String = "neutral",
    val wallpaperDim: Float = .95f,
    val showClock: Boolean = true,
    val prismEffects: Boolean = true,
    val prismIcons: Boolean = true,
    val loading: Boolean = true,
    val error: Boolean = false,
)

class LauncherModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences("launcher", Context.MODE_PRIVATE)
    private val launcher = application.getSystemService(LauncherApps::class.java)
    private val users = application.getSystemService(UserManager::class.java)
    private val mutableState = MutableStateFlow(LauncherState(
        folders = readFolders(), favorites = readList("favorites"), recent = readList("recent"), aliases = readAliases(),
        showAllIndexLetters = preferences.getBoolean("showAllIndexLetters", true),
        koreanIndexSyllables = preferences.getBoolean("koreanIndexSyllables", true),
        showKoreanIndex = preferences.getBoolean("showKoreanIndex", true),
        selectedIndexOnly = preferences.getBoolean("selectedIndexOnly", false),
        themeAccent = preferences.getString("themeAccent", "neutral") ?: "neutral",
        wallpaperDim = preferences.getFloat("wallpaperDim", .95f).coerceIn(.35f, 1f),
        showClock = preferences.getBoolean("showClock", true),
        prismEffects = preferences.getBoolean("prismEffects", true),
        prismIcons = preferences.getBoolean("prismIcons", true),
    ))
    val state = mutableState.asStateFlow()
    private var refreshJob: Job? = null
    private var iconRevision = 0
    private var appLocale: Locale = application.resources.configuration.locales[0]
    private val callback = object : LauncherApps.Callback() {
        override fun onShortcutsChanged(packageName: String, shortcuts: List<ShortcutInfo>, user: UserHandle) { iconRevision++; refresh() }
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

    private fun readFolders(): List<LauncherFolder> = runCatching {
        val array = JSONArray(preferences.getString("folders", "[]"))
        List(array.length()) { index ->
            val item = array.getJSONObject(index)
            val apps = item.getJSONArray("apps")
            LauncherFolder(item.getString("id"), item.getString("name"),
                List(apps.length()) { apps.getString(it) }.distinct())
        }.distinctBy { it.id }
    }.getOrDefault(emptyList())

    private fun persistFolders(folders: List<LauncherFolder>) {
        val json = JSONArray().apply { folders.forEach {
            put(JSONObject().put("id", it.id).put("name", it.name).put("apps", JSONArray(it.appIds)))
        } }
        preferences.edit().putString("folders", json.toString()).apply()
        mutableState.value = mutableState.value.copy(folders = folders)
    }

    fun saveFolder(id: String?, name: String, appIds: List<String>) {
        val title = name.trim().take(60)
        if (title.isBlank()) return
        val folder = LauncherFolder(id ?: UUID.randomUUID().toString(), title, appIds.distinct())
        val existing = mutableState.value.folders
        persistFolders(if (existing.any { it.id == folder.id }) existing.map { if (it.id == folder.id) folder else it }
            else existing + folder)
    }

    fun removeFolder(id: String) = persistFolders(mutableState.value.folders.filterNot { it.id == id })

    fun moveFolder(id: String, direction: Int) {
        val next = mutableState.value.folders.toMutableList()
        val from = next.indexOfFirst { it.id == id }
        val to = from + direction
        if (from < 0 || to !in next.indices) return
        next.add(to, next.removeAt(from))
        persistFolders(next)
    }

    fun hasShortcutPermission(): Boolean = runCatching { launcher.hasShortcutHostPermission() }.getOrDefault(false)

    suspend fun shortcuts(app: LauncherApp): Result<List<ShortcutInfo>> = withContext(Dispatchers.IO) {
        runCatching {
            check(launcher.hasShortcutHostPermission())
            launcher.getShortcuts(LauncherApps.ShortcutQuery().setPackage(app.component.packageName)
                .setQueryFlags(LauncherApps.ShortcutQuery.FLAG_MATCH_MANIFEST or LauncherApps.ShortcutQuery.FLAG_MATCH_DYNAMIC or
                    LauncherApps.ShortcutQuery.FLAG_MATCH_PINNED), app.user).orEmpty()
                .filter { it.isEnabled && (it.activity == null || it.activity == app.component) }
                .distinctBy { it.id }.sortedBy { it.rank }
        }
    }

    fun launchShortcut(shortcut: ShortcutInfo): Boolean = runCatching {
        launcher.startShortcut(shortcut, null, null)
    }.isSuccess

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
                    fun label(info: LauncherActivityInfo, labelLocale: Locale): String = runCatching {
                        val metadata = application.packageManager.getActivityInfo(info.componentName, 0)
                        metadata.nonLocalizedLabel?.toString() ?: run {
                            val labelResource = metadata.labelRes.takeIf { it != 0 }
                                ?: metadata.applicationInfo.labelRes
                            if (labelResource == 0) info.label.toString() else {
                                val packageContext = localizedPackages.getOrPut("${info.componentName.packageName}:${labelLocale.toLanguageTag()}") {
                                    val base = application.createPackageContext(info.componentName.packageName, 0)
                                    base.createConfigurationContext(Configuration(base.resources.configuration).apply { setLocale(labelLocale) })
                                }
                                packageContext.getString(labelResource)
                            }
                        }
                    }.getOrElse { info.label.toString() }
                    launcher.getActivityList(null, user)
                        .filter { it.componentName.packageName != getApplication<Application>().packageName }
                        .map {
                            val displayLabel = label(it, locale)
                            val englishLabel = if (locale.language == "en") displayLabel else label(it, Locale.ENGLISH)
                            LauncherApp("$serial:${it.componentName.flattenToString()}", displayLabel, it.componentName, user, iconRevision, englishLabel)
                        }
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

    fun setShowAllIndexLetters(enabled: Boolean) {
        preferences.edit().putBoolean("showAllIndexLetters", enabled).apply()
        mutableState.value = mutableState.value.copy(showAllIndexLetters = enabled)
    }

    fun setKoreanIndexSyllables(enabled: Boolean) {
        preferences.edit().putBoolean("koreanIndexSyllables", enabled).apply()
        mutableState.value = mutableState.value.copy(koreanIndexSyllables = enabled)
    }

    fun setShowKoreanIndex(enabled: Boolean) {
        preferences.edit().putBoolean("showKoreanIndex", enabled).apply()
        mutableState.value = mutableState.value.copy(showKoreanIndex = enabled)
    }

    fun setThemeAccent(value: String) {
        if (value !in listOf("neutral", "blue", "sage", "violet")) return
        preferences.edit().putString("themeAccent", value).apply()
        mutableState.value = mutableState.value.copy(themeAccent = value)
    }

    fun setWallpaperDim(value: Float) {
        val dim = value.coerceIn(.35f, 1f)
        preferences.edit().putFloat("wallpaperDim", dim).apply()
        mutableState.value = mutableState.value.copy(wallpaperDim = dim)
    }

    fun setShowClock(value: Boolean) {
        preferences.edit().putBoolean("showClock", value).apply()
        mutableState.value = mutableState.value.copy(showClock = value)
    }

    fun setPrismEffects(enabled: Boolean) {
        preferences.edit().putBoolean("prismEffects", enabled).apply()
        mutableState.value = mutableState.value.copy(prismEffects = enabled)
    }

    fun setPrismIcons(enabled: Boolean) {
        preferences.edit().putBoolean("prismIcons", enabled).apply()
        mutableState.value = mutableState.value.copy(prismIcons = enabled)
    }

    fun setSelectedIndexOnly(enabled: Boolean) {
        preferences.edit().putBoolean("selectedIndexOnly", enabled).apply()
        mutableState.value = mutableState.value.copy(selectedIndexOnly = enabled)
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
