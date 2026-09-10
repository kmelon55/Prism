package app.prism.launcher

import android.app.role.RoleManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.flow.MutableStateFlow

class MainActivity : ComponentActivity() {
    private val model: LauncherModel by viewModels()
    lateinit var widgets: WidgetController
        private set
    val homeRequest = MutableStateFlow(0)
    val defaultHome = MutableStateFlow(false)
    val lockRequested = MutableStateFlow(false)
    private val homeRoleRequest = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        refreshHomeRole()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        homeRequest.value = savedInstanceState?.getInt("homeRequest") ?: 0
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        widgets = WidgetController(this)
        widgets.onError = { message(R.string.widget_failed) }
        lockRequested.value = getSharedPreferences("launcher", MODE_PRIVATE).getBoolean("screenLock", false)
        setContent { PrismLauncher(model, this) }
    }

    override fun onStart() {
        super.onStart()
        widgets.host.startListening()
    }

    override fun onStop() {
        widgets.host.stopListening()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        model.refreshForLocale(resources.configuration.locales[0])
        refreshHomeRole()
    }

    private fun refreshHomeRole() {
        defaultHome.value = if (Build.VERSION.SDK_INT >= 29) {
            getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_HOME)
        } else {
            packageManager.resolveActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)
                ?.activityInfo?.packageName == packageName
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.hasCategory(Intent.CATEGORY_HOME)) homeRequest.value++
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putInt("homeRequest", homeRequest.value)
        super.onSaveInstanceState(outState)
    }

    @Deprecated("Used by the platform AppWidgetHost configuration API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == WidgetController.CONFIGURE_REQUEST) widgets.configurationResult(resultCode)
    }

    fun chooseHome() {
        if (Build.VERSION.SDK_INT >= 29) {
            val role = getSystemService(RoleManager::class.java)
            if (role.isRoleAvailable(RoleManager.ROLE_HOME) && !role.isRoleHeld(RoleManager.ROLE_HOME)) {
                // A result launch gives the system dialog the requesting package identity.
                runCatching { homeRoleRequest.launch(role.createRequestRoleIntent(RoleManager.ROLE_HOME)) }
                    .onFailure { openSystem(Intent(Settings.ACTION_HOME_SETTINGS)) }
                return
            }
        }
        openSystem(Intent(Settings.ACTION_HOME_SETTINGS))
    }

    fun chooseWallpaper() = openSystem(Intent(Intent.ACTION_SET_WALLPAPER))

    fun setScreenLock(enabled: Boolean) {
        getSharedPreferences("launcher", MODE_PRIVATE).edit().putBoolean("screenLock", enabled).apply()
        lockRequested.value = enabled
        if (enabled) {
            openSystem(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        } else ScreenLockService.disable()
    }

    fun lockScreen() {
        if (lockRequested.value && !ScreenLockService.lock()) message(R.string.screen_lock_permission)
    }

    fun appInfo(app: LauncherApp) {
        runCatching {
            getSystemService(android.content.pm.LauncherApps::class.java)
                .startAppDetailsActivity(app.component, app.user, null, null)
        }.onFailure { message(R.string.system_action_failed) }
    }

    private fun openSystem(intent: Intent) {
        runCatching { startActivity(intent) }.onFailure { message(R.string.system_action_failed) }
    }

    fun message(resource: Int) { Toast.makeText(this, resource, Toast.LENGTH_SHORT).show() }
}
