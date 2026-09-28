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
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.sin

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

@Composable
internal fun PrismTheme(effects: Boolean, icons: Boolean, accent: String, wallpaperDim: Float, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalPrismEffects provides effects, LocalPrismIcons provides icons,
        LocalPrismAccent provides themeAccent(accent), LocalWallpaperDim provides wallpaperDim) {
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

/** All illumination is cached static drawing: no animation loop or off-screen blur. */
@Composable
internal fun PrismBackdrop(modifier: Modifier = Modifier) {
    val effects = LocalPrismEffects.current
    val dim = LocalWallpaperDim.current
    Canvas(modifier.fillMaxSize()) {
        drawRect(Color.Black.copy(alpha = dim))
        if (effects) {
            drawRect(Brush.radialGradient(listOf(Color.White.copy(alpha = .035f), Color.Transparent),
                Offset(size.width * .12f, 0f), size.width * 1.1f))
        }
    }
}

internal fun Modifier.prismPanel(effects: Boolean, radius: Dp = 28.dp, luminous: Boolean = true): Modifier {
    val shape = RoundedCornerShape(radius)
    return shadow(20.dp, shape, ambientColor = Color(0x66000000), spotColor = Color(0x99000000))
        .clip(shape)
        .background(Brush.linearGradient(if (effects)
            listOf(Color(0x382E2E2E), Color(0x68101010), Color(0x38202020))
            else listOf(Color(0xFF181818), Color(0xFF101010))))
        .drawWithCache {
            val rim = Brush.linearGradient(listOf(Color.White.copy(alpha = .28f), Color.White.copy(alpha = .05f),
                Color.White.copy(alpha = .12f), Color.White.copy(alpha = .16f)))
            val innerRim = Brush.verticalGradient(listOf(Color.White.copy(alpha = .12f), Color.Transparent, Color.Black.copy(alpha = .28f)))
            val sheen = Brush.verticalGradient(listOf(Color.White.copy(alpha = .06f), Color.White.copy(alpha = .012f)))
            val reflection = Path().apply {
                moveTo(0f, 0f); lineTo(size.width, 0f); lineTo(size.width, size.height * .15f)
                cubicTo(size.width * .68f, size.height * .11f, size.width * .42f, size.height * .5f, 0f, size.height * .46f)
                close()
            }
            val bloom = Brush.radialGradient(listOf(Color.White.copy(alpha = .025f), Color.Transparent),
                Offset(size.width * .86f, size.height * .95f), size.width * .7f)
            onDrawBehind {
                if (effects) {
                    drawPath(reflection, sheen)
                    if (luminous) drawRect(bloom)
                }
                val inset = .6.dp.toPx()
                drawRoundRect(if (effects) rim else Brush.linearGradient(listOf(Color(0xFF383838), Color(0xFF242424))),
                    topLeft = Offset(inset, inset), size = Size(size.width - inset * 2, size.height - inset * 2),
                    cornerRadius = CornerRadius(radius.toPx()), style = Stroke(1.dp.toPx()))
                if (effects) {
                    val inner = 2.dp.toPx()
                    drawRoundRect(innerRim, topLeft = Offset(inner, inner),
                        size = Size((size.width - inner * 2).coerceAtLeast(0f), (size.height - inner * 2).coerceAtLeast(0f)),
                        cornerRadius = CornerRadius((radius.toPx() - inner).coerceAtLeast(0f)), style = Stroke(.7.dp.toPx()))
                }
            }
        }
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
