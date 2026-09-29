package app.prism.launcher

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal val Ink = Color(0xFF050505)
internal val Paper = Color(0xFFF2F2F2)
internal val Muted = Color(0xFF969696)
internal val LocalPrismAccent = staticCompositionLocalOf { Color(0xFFE0E0E0) }
internal val LocalWallpaperDim = staticCompositionLocalOf { .95f }
internal val PrismAccent: Color @Composable get() = LocalPrismAccent.current
internal fun themeAccent(name: String): Color = when (name) {
    "blue" -> Color(0xFFA8C7FA)
    "sage" -> Color(0xFFB3C9B5)
    "violet" -> Color(0xFFC5B9DC)
    else -> Color(0xFFE0E0E0)
}
internal val PrismCyan = Color(0xFF91DFE8)
internal val PrismEmber = Color(0xFFFF7755)
internal val LocalPrismEffects = staticCompositionLocalOf { true }
internal val LocalPrismIcons = staticCompositionLocalOf { true }
internal val LocalPrismAppearance = staticCompositionLocalOf { PrismAppearance.Matte }

@Composable
internal fun PrismTheme(effects: Boolean, icons: Boolean, accent: String, wallpaperDim: Float,
    appearance: PrismAppearance = if (effects) PrismAppearance.Matte else PrismAppearance.Flat,
    glassBackgroundRevision: Long = 0L, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalPrismEffects provides effects, LocalPrismIcons provides icons,
        LocalPrismAccent provides themeAccent(accent), LocalWallpaperDim provides wallpaperDim,
        LocalPrismAppearance provides appearance) {
        GlassEnvironment(appearance == PrismAppearance.Liquid && android.os.Build.VERSION.SDK_INT >= 33, glassBackgroundRevision) {
        MaterialTheme(
            colorScheme = darkColorScheme(
                primary = themeAccent(accent), onPrimary = Ink,
                primaryContainer = Color(0xFF303030), onPrimaryContainer = Paper,
                secondary = themeAccent(accent), onSecondary = Ink, secondaryContainer = Color(0xFF262626), onSecondaryContainer = Paper,
                tertiary = PrismEmber, background = Ink, onBackground = Paper,
                surface = Color(0xFF111111), onSurface = Paper, onSurfaceVariant = Muted,
                surfaceContainer = Color(0xFF181818), surfaceContainerHigh = Color(0xFF222222),
                surfaceContainerHighest = Color(0xFF2C2C2C), surfaceVariant = Color(0xFF242424),
                outline = Color(0xFF626262), outlineVariant = Color(0xFF353535),
            ),
            shapes = Shapes(small = RoundedCornerShape(14.dp), medium = RoundedCornerShape(20.dp),
                large = RoundedCornerShape(28.dp), extraLarge = RoundedCornerShape(32.dp)),
            typography = Typography(
                headlineSmall = androidx.compose.ui.text.TextStyle(fontSize = 24.sp, fontWeight = FontWeight.Medium, letterSpacing = (-.5).sp),
                titleLarge = androidx.compose.ui.text.TextStyle(fontSize = 23.sp, fontWeight = FontWeight.Medium, letterSpacing = (-.4).sp),
                titleMedium = androidx.compose.ui.text.TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium),
                labelSmall = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 10.sp, letterSpacing = 1.sp),
            ), content = content,
        )
        }
    }
}

/** The glass sampler and visible background use the same center-cropped, app-owned bitmap. */
@Composable
internal fun PrismBackdrop(modifier: Modifier = Modifier) {
    val effects = LocalPrismEffects.current
    val dim = LocalWallpaperDim.current
    val scene = LocalGlassScene.current
    val paint = remember { android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG) }
    Canvas(modifier.fillMaxSize()) {
        if (scene != null) drawIntoCanvas {
            it.nativeCanvas.drawBitmap(scene.bitmap, null, glassBackdropRect(scene.bitmap, size), paint)
        }
        drawRect(Color.Black.copy(alpha = dim))
        if (effects && scene == null) {
            drawRect(Brush.radialGradient(listOf(Color.White.copy(alpha = .035f), Color.Transparent),
                Offset(size.width * .12f, 0f), size.width * 1.1f))
        }
    }
}

/** Matte raised material. Soft opposing shadows are cached geometry, not animated blur. */
@Composable
internal fun Modifier.prismPanel(effects: Boolean, radius: Dp = 28.dp, luminous: Boolean = true): Modifier {
    val scene = LocalGlassScene.current
    if (effects && LocalPrismAppearance.current == PrismAppearance.Liquid && scene != null && android.os.Build.VERSION.SDK_INT >= 33) {
        return liquidGlassPanel(scene, radius)
    }
    return mattePanel(effects, radius, luminous)
}

private fun Modifier.mattePanel(effects: Boolean, radius: Dp, luminous: Boolean): Modifier {
    val shape = RoundedCornerShape(radius)
    if (!effects) return shadow(20.dp, shape, ambientColor = Color(0x66000000), spotColor = Color(0x99000000))
        .clip(shape)
        .background(Brush.linearGradient(listOf(Color(0xFF181818), Color(0xFF101010))))
        .border(1.dp, Brush.linearGradient(listOf(Color(0xFF383838), Color(0xFF242424))), shape)

    return drawWithCache {
        val compact = size.minDimension <= 64.dp.toPx()
        val corner = radius.toPx().coerceAtMost(size.minDimension / 2f)
        val softness = (if (compact) 6.dp else 12.dp).toPx()
        val lift = (if (compact) 3.dp else 5.dp).toPx()
        val layers = (12 downTo 1).map { step ->
            val fraction = step / 12f
            softness * fraction to (1f - fraction) / 12f
        }
        onDrawBehind {
            // Draw outside the clipping boundary: light above/left, deeper shade below/right.
            layers.forEach { (spread, opacity) ->
                val shadowSize = Size(size.width + spread * 2f, size.height + spread * 2f)
                val shadowCorner = CornerRadius(corner + spread)
                drawRoundRect(Color.Black.copy(alpha = opacity * 1.8f),
                    topLeft = Offset(lift - spread, lift - spread), size = shadowSize, cornerRadius = shadowCorner)
                drawRoundRect(Color.White.copy(alpha = opacity * if (luminous) .16f else .12f),
                    topLeft = Offset(-lift * .6f - spread, -lift * .6f - spread),
                    size = shadowSize, cornerRadius = shadowCorner)
            }
        }
    }.clip(shape).drawWithCache {
        val compact = size.minDimension <= 64.dp.toPx()
        val corner = radius.toPx().coerceAtMost(size.minDimension / 2f)
        val body = Brush.linearGradient(
            0f to Color(if (compact) 0xFF242629 else 0xFF202225),
            .46f to Color(0xFF191B1E),
            1f to Color(0xFF121416),
            start = Offset.Zero, end = Offset(size.width * .8f, size.height),
        )
        val crown = Brush.radialGradient(
            listOf(Color.White.copy(alpha = .025f), Color.Transparent),
            center = Offset(size.width * .18f, 0f), radius = maxOf(size.maxDimension * .8f, 1f),
        )
        val edge = Brush.linearGradient(
            0f to Color.White.copy(alpha = .09f),
            .35f to Color.White.copy(alpha = .018f),
            .65f to Color.Transparent,
            1f to Color.Black.copy(alpha = .24f),
            start = Offset.Zero, end = Offset(size.width, size.height),
        )
        onDrawBehind {
            drawRect(body)
            drawRect(crown)
            val inset = .5.dp.toPx()
            drawRoundRect(edge, topLeft = Offset(inset, inset),
                size = Size((size.width - inset * 2).coerceAtLeast(0f), (size.height - inset * 2).coerceAtLeast(0f)),
                cornerRadius = CornerRadius((corner - inset).coerceAtLeast(0f)), style = Stroke(1.dp.toPx()))
        }
    }
}

/** A quiet inset for information within a raised panel. */
@Composable
internal fun Modifier.prismInset(effects: Boolean, radius: Dp = 18.dp): Modifier {
    if (!effects) return this
    if (LocalPrismAppearance.current == PrismAppearance.Liquid) return background(Color.Black.copy(alpha = .13f), RoundedCornerShape(radius))
    return clip(RoundedCornerShape(radius)).drawWithCache {
        val corner = radius.toPx().coerceAtMost(size.minDimension / 2f)
        val body = Brush.linearGradient(listOf(Color(0xFF0D0F11), Color(0xFF17191C)))
        val edge = Brush.verticalGradient(listOf(Color.Black.copy(alpha = .5f), Color.Transparent, Color.White.copy(alpha = .045f)))
        val shade = Brush.verticalGradient(listOf(Color.Black.copy(alpha = .25f), Color.Transparent), endY = 8.dp.toPx())
        onDrawBehind {
            drawRect(body)
            drawRect(shade)
            val inset = .5.dp.toPx()
            drawRoundRect(edge, topLeft = Offset(inset, inset),
                size = Size((size.width - inset * 2).coerceAtLeast(0f), (size.height - inset * 2).coerceAtLeast(0f)),
                cornerRadius = CornerRadius((corner - inset).coerceAtLeast(0f)), style = Stroke(1.dp.toPx()))
        }
    }
}

internal fun prismIconAccent(id: String): Color {
    val colors = listOf(Color(0xFF61C4EE), Color(0xFFFD796A), Color(0xFFAD96EB),
        Color(0xFF68CCB0), Color(0xFFE8BC67), Color(0xFFE387B3))
    return colors[Math.floorMod(id.hashCode(), colors.size)]
}

@Composable
internal fun PrismPanel(modifier: Modifier = Modifier, luminous: Boolean = true, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.prismPanel(LocalPrismEffects.current, luminous = luminous), content = content)
}

@Composable
internal fun PrismRule(modifier: Modifier = Modifier) {
    val effects = LocalPrismEffects.current
    Spacer(modifier.fillMaxWidth().height(1.dp).background(
        Brush.horizontalGradient(if (effects) listOf(Color.Transparent, Color.White.copy(alpha = .22f), Color.White.copy(alpha = .1f), Color.Transparent)
        else listOf(Color.Transparent, Muted.copy(alpha = .2f), Color.Transparent))))
}

@Composable
internal fun PrismSheetHandle() {
    val view = LocalView.current
    SideEffect {
        // The app stays dark even when Android's system theme is light.
        view.post {
            if (view.isAttachedToWindow) (view.parent as? DialogWindowProvider)?.window?.let { window ->
                WindowCompat.getInsetsController(window, window.decorView).apply {
                    isAppearanceLightStatusBars = false
                    isAppearanceLightNavigationBars = false
                }
            }
        }
    }
    Column(Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 22.dp)) {
        PrismRule(Modifier.padding(horizontal = 48.dp))
        Spacer(Modifier.height(12.dp))
        Box(Modifier.width(32.dp).height(3.dp).background(Muted.copy(alpha = .4f), RoundedCornerShape(2.dp))
            .align(androidx.compose.ui.Alignment.CenterHorizontally))
    }
}
