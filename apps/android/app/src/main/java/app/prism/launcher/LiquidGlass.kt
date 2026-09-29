package app.prism.launcher

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.RuntimeShader
import android.graphics.Shader
import androidx.annotation.RequiresApi
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.foundation.shape.RoundedCornerShape
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

internal class GlassScene(val bitmap: Bitmap) {
    var viewport by mutableStateOf(Size(1f, 1f))
    var rootOrigin by mutableStateOf(Offset.Zero)
}

internal val LocalGlassScene = staticCompositionLocalOf<GlassScene?> { null }

@Composable
internal fun GlassEnvironment(enabled: Boolean, revision: Long, content: @Composable () -> Unit) {
    val context = LocalContext.current.applicationContext
    val bitmap by produceState<Bitmap?>(null, enabled, revision) {
        value = if (enabled) withContext(Dispatchers.IO) { GlassBackgroundStore.load(context) } else null
    }
    // Bitmaps retire through GC after render-thread references are released, never via eager recycle.
    val scene = remember(bitmap, enabled) { if (enabled) bitmap?.let(::GlassScene) else null }
    CompositionLocalProvider(LocalGlassScene provides scene, content = content)
}

@Composable
internal fun Modifier.glassViewport(): Modifier {
    val scene = LocalGlassScene.current ?: return this
    return onSizeChanged { scene.viewport = Size(it.width.toFloat().coerceAtLeast(1f), it.height.toFloat().coerceAtLeast(1f)) }
        .onGloballyPositioned { scene.rootOrigin = it.positionInWindow() }
}

internal fun glassBackdropRect(bitmap: Bitmap, viewport: Size): RectF {
    val scale = max(viewport.width / bitmap.width, viewport.height / bitmap.height)
    val width = bitmap.width * scale
    val height = bitmap.height * scale
    val x = (viewport.width - width) / 2f
    val y = (viewport.height - height) / 2f
    return RectF(x, y, x + width, y + height)
}

@RequiresApi(33)
@Composable
internal fun Modifier.liquidGlassPanel(scene: GlassScene, radius: Dp): Modifier {
    val dim = LocalWallpaperDim.current
    var origin by remember { mutableStateOf(Offset.Zero) }
    return onGloballyPositioned { origin = it.positionInWindow() }
        .clip(RoundedCornerShape(radius))
        .drawWithCache {
            val shader = RuntimeShader(LIQUID_GLASS_SHADER)
            val sampler = BitmapShader(scene.bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply {
                setFilterMode(BitmapShader.FILTER_MODE_LINEAR)
            }
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = shader }
            val matrix = Matrix()
            val shaderDensity = density
            shader.setFloatUniform("resolution", size.width, size.height)
            shader.setFloatUniform("radius", minOf(radius.toPx(), size.minDimension / 2f))
            shader.setFloatUniform("density", shaderDensity)
            shader.setFloatUniform("dim", dim)
            onDrawBehind {
                val viewport = scene.viewport
                val destination = glassBackdropRect(scene.bitmap, viewport)
                matrix.setScale(destination.width() / scene.bitmap.width, destination.height() / scene.bitmap.height)
                matrix.postTranslate(destination.left, destination.top)
                sampler.setLocalMatrix(matrix)
                shader.setInputShader("backdrop", sampler)
                shader.setFloatUniform("viewport", viewport.width, viewport.height)
                val relativeOrigin = origin - scene.rootOrigin
                shader.setFloatUniform("origin", relativeOrigin.x, relativeOrigin.y)
                drawIntoCanvas { it.nativeCanvas.drawRect(0f, 0f, size.width, size.height, paint) }
            }
        }
}
