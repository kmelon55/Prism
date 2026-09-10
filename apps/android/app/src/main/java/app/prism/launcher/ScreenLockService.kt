package app.prism.launcher

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.lang.ref.WeakReference

/** Only an explicit home-screen double tap invokes the system lock action. No event subscriptions. */
class ScreenLockService : AccessibilityService() {
    override fun onServiceConnected() {
        instance = WeakReference(this)
        mutableConnected.value = true
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (instance.get() === this) {
            instance.clear()
            mutableConnected.value = false
        }
        super.onDestroy()
    }

    companion object {
        private var instance = WeakReference<ScreenLockService>(null)
        private val mutableConnected = MutableStateFlow(false)
        val connected = mutableConnected.asStateFlow()
        fun lock(): Boolean = instance.get()?.performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN) == true
        fun disable() { instance.get()?.disableSelf() }
    }
}
