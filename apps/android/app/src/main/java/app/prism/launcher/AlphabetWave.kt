package app.prism.launcher

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max

internal data class WaveLetter(val x: Float, val y: Float, val emphasis: Float)

/** Fixed vertical slots; only horizontal displacement follows the pointer. */
internal object AlphabetWave {
    fun indexAt(y: Float, height: Float, count: Int): Int =
        if (count <= 1 || height <= 0f) 0 else (y / height * count).toInt().coerceIn(0, count - 1)

    fun positionAt(y: Float, height: Float, count: Int): Float =
        if (count <= 1 || height <= 0f) 0f else (y / height * count - .5f).coerceIn(0f, (count - 1).toFloat())

    fun letter(index: Int, count: Int, height: Float, restX: Float, fingerX: Float,
               fingerY: Float, openness: Float): WaveLetter {
        val baseY = (index + .5f) * height / count.coerceAtLeast(1)
        val focus = fingerY.coerceIn(0f, height)
        val pull = (restX - fingerX).coerceAtLeast(0f)
        val edgeProximity = (1f - pull / 80f).coerceIn(0f, 1f)
        val edgeEmphasis = edgeProximity * edgeProximity * (3f - 2f * edgeProximity)
        // Sharpen the first touch slightly, blending back to the existing curve as it is pulled in.
        val radius = (max(116f, height * .28f) + pull * .18f) * (1f - .08f * edgeEmphasis)
        val delta = baseY - focus
        val weight = exp(-.5f * delta * delta / (radius * radius))
        val depth = max(92f, restX - fingerX + 92f).coerceAtMost((restX - 24f).coerceAtLeast(0f))
        return WaveLetter(restX - depth * weight * openness,
            baseY,
            exp(-abs(delta) / 64f) * openness)
    }
}
