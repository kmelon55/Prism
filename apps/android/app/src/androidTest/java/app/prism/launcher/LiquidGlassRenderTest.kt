package app.prism.launcher

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.net.Uri
import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

@RunWith(AndroidJUnit4::class)
class LiquidGlassRenderTest {
    @get:Rule val rule = createComposeRule()

    @Test fun hardwareShaderRefractsBackdropWithoutTouchDrivenOrIdleChanges() {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        val bitmap = Bitmap.createBitmap(800, 1600, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint()
        for (x in 0 until 800 step 12) {
            paint.color = if ((x / 12) % 2 == 0) android.graphics.Color.WHITE else android.graphics.Color.BLACK
            canvas.drawRect(x.toFloat(), 0f, x + 12f, 1600f, paint)
        }
        val scene = GlassScene(bitmap)
        val showLens = mutableStateOf(true)
        rule.setContent {
            CompositionLocalProvider(LocalGlassScene provides scene, LocalWallpaperDim provides .15f,
                LocalPrismAppearance provides PrismAppearance.Liquid) {
                Box(Modifier.fillMaxSize().glassViewport()) {
                    PrismBackdrop(Modifier.matchParentSize())
                    Box(Modifier.padding(start = 32.dp, top = 160.dp).size(280.dp, 220.dp)
                        .then(if (showLens.value) Modifier.prismPanel(true) else Modifier).testTag("lens"))
                }
            }
        }
        fun capture() = rule.onRoot().captureToImage().asAndroidBitmap()
        val bounds = rule.onNodeWithTag("lens").fetchSemanticsNode().boundsInRoot
        val initial = capture()
        val idle = capture()
        assertEquals("No time-driven changes at rest", 0, changes(initial, idle))
        rule.onNodeWithTag("lens").performTouchInput { down(Offset(width * .9f, height * .9f)) }
        val touched = capture()
        rule.onNodeWithTag("lens").performTouchInput { up() }
        assertEquals("Touch does not change the optical surface", 0, changes(initial, touched))
        val lens = capture()
        rule.runOnIdle { showLens.value = false }
        val plain = capture()
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        var displaced = 0
        // Sample away from the thin highlight: black/white boundaries must move, not merely tint.
        val left = bounds.left.roundToInt()
        val top = bounds.top.roundToInt()
        for (y in top + (50 * density).roundToInt() until bounds.bottom.toInt() - (50 * density).roundToInt() step 3) {
            for (x in left + (5 * density).roundToInt() until left + (16 * density).roundToInt()) {
                if (brightness(plain.getPixel(x, y)) > 170 && brightness(lens.getPixel(x, y)) < 90) displaced++
            }
        }
        val folder = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null)!!
        listOf("glass-optics-rest.png" to initial, "glass-optics-touch.png" to touched, "glass-optics-plain.png" to plain).forEach { (name, shot) ->
            File(folder, name).outputStream().use { shot.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        assertTrue("The shader displaces actual backdrop edges ($displaced pixels; bounds=$bounds)", displaced > 50)
    }

    @Test fun importedBackgroundIsBoundedAndADecodeFailurePreservesThePreviousImage() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val saved = File(context.filesDir, "glass-background.png")
        val previous = if (saved.exists()) saved.readBytes() else null
        val input = File.createTempFile("glass-import-", ".png", context.cacheDir)
        try {
            val source = Bitmap.createBitmap(2400, 1200, Bitmap.Config.ARGB_8888)
            source.eraseColor(android.graphics.Color.CYAN)
            input.outputStream().use { source.compress(Bitmap.CompressFormat.PNG, 100, it) }
            source.recycle()
            GlassBackgroundStore.replace(context, Uri.fromFile(input))
            val loaded = GlassBackgroundStore.load(context)
            assertEquals(1920, loaded.width)
            assertEquals(960, loaded.height)
            assertEquals(android.graphics.Color.CYAN, loaded.getPixel(800, 400))
            loaded.recycle()
            val good = saved.readBytes()
            input.writeText("not an image")
            assertThrows(Exception::class.java) { GlassBackgroundStore.replace(context, Uri.fromFile(input)) }
            assertArrayEquals(good, saved.readBytes())
            GlassBackgroundStore.replace(context, null)
            assertFalse(saved.exists())
            val fallback = GlassBackgroundStore.load(context)
            assertTrue(fallback.width > 0 && fallback.height > 0)
            fallback.recycle()
        } finally {
            if (previous == null) saved.delete() else saved.writeBytes(previous)
            input.delete()
        }
    }

    private fun brightness(pixel: Int) = ((pixel shr 16 and 255) + (pixel shr 8 and 255) + (pixel and 255)) / 3
    private fun changes(a: Bitmap, b: Bitmap): Int {
        var count = 0
        for (y in 0 until a.height step 3) for (x in 0 until a.width step 3) {
            if (abs(brightness(a.getPixel(x, y)) - brightness(b.getPixel(x, y))) > 3) count++
        }
        return count
    }
}
