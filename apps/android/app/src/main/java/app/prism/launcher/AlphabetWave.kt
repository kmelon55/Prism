package app.prism.launcher

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max

internal data class WaveLetter(val x: Float, val y: Float, val emphasis: Float)

/** Coordinates are density-independent. Hit testing stays in the unwarped touch rail. */
internal object AlphabetWave {
    fun indexAt(y: Float, height: Float, count: Int): Int =
        if (count <= 1 || height <= 0f) 0 else (y / height * count).toInt().coerceIn(0, count - 1)

    fun letter(index: Int, count: Int, height: Float, restX: Float, fingerX: Float,
               fingerY: Float, openness: Float): WaveLetter {
        val baseY = (index + .5f) * height / count.coerceAtLeast(1)
        val focus = fingerY.coerceIn(0f, height)
        val radius = max(82f, height * .18f)
        val delta = baseY - focus
        val weight = exp(-.5f * delta * delta / (radius * radius))
        val depth = max(104f, restX - fingerX + 64f).coerceAtMost((restX - 24f).coerceAtLeast(0f))
        // Expand the neighborhood vertically, then normalize its ends back into the rail bounds.
        // The mapping stays monotonic, so fast reversals cannot swap adjacent letter positions.
        fun expanded(y: Float): Float {
            val d = y - focus
            return y + .85f * d * exp(-d * d / (radius * radius))
        }
        val start = expanded(0f)
        val end = expanded(height)
        val expandedY = (expanded(baseY) - start) / (end - start).coerceAtLeast(1f) * height
        val active = index == indexAt(focus, height, count)
        val x = if (active) (restX - depth * weight).coerceAtMost(fingerX - 64f).coerceAtLeast(24f)
                else restX - depth * weight
        val localEmphasis = exp(-abs(delta) / 44f)
        return WaveLetter(restX + (x - restX) * openness,
            baseY + (expandedY - baseY) * openness,
            localEmphasis * openness)
    }
}
