package app.prism.launcher

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.net.Uri
import android.util.AtomicFile
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/** Only app-owned pixels enter the optical shader; no wallpaper read or storage permission. */
internal object GlassBackgroundStore {
    private fun file(context: Context) = AtomicFile(File(context.filesDir, "glass-background.png"))

    fun replace(context: Context, uri: Uri?) {
        val target = file(context)
        if (uri == null) { target.delete(); return }
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
            val scale = minOf(1f, 1920f / max(info.size.width, info.size.height))
            decoder.setTargetSize(max(1, (info.size.width * scale).roundToInt()), max(1, (info.size.height * scale).roundToInt()))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        // Decode before replacing: cancellation/bad input never destroys the previous selection.
        try {
            val stream = target.startWrite()
            try {
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
                target.finishWrite(stream)
            } catch (error: Throwable) {
                target.failWrite(stream)
                throw error
            }
        } finally { bitmap.recycle() }
    }

    fun load(context: Context): Bitmap = runCatching {
        file(context).openRead().use { BitmapFactory.decodeStream(it) }
    }.getOrNull() ?: defaultBitmap()

    /** A still, high-contrast field makes displaced edges visible without a perpetual animation. */
    private fun defaultBitmap(): Bitmap {
        val width = 960f
        val height = 1920f
        val bitmap = Bitmap.createBitmap(width.toInt(), height.toInt(), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = LinearGradient(0f, 0f, width, height,
            intArrayOf(Color.rgb(12, 25, 57), Color.rgb(24, 62, 92), Color.rgb(9, 17, 38)), null, Shader.TileMode.CLAMP)
        canvas.drawPaint(paint)
        val ribbon = Path().apply {
            moveTo(-180f, 150f)
            cubicTo(270f, 470f, 870f, 70f, 1070f, 480f)
            cubicTo(1170f, 730f, 330f, 690f, 140f, 1120f)
            lineTo(-100f, 870f)
            cubicTo(120f, 450f, 850f, 600f, 820f, 410f)
            cubicTo(740f, 210f, 260f, 720f, -180f, 400f)
            close()
        }
        paint.shader = LinearGradient(90f, 100f, 880f, 1100f,
            intArrayOf(Color.rgb(39, 141, 205), Color.rgb(116, 218, 214), Color.rgb(49, 94, 176)), null, Shader.TileMode.CLAMP)
        canvas.drawPath(ribbon, paint)
        val warm = Path().apply {
            moveTo(1040f, 1000f)
            cubicTo(530f, 980f, 1070f, 1460f, 150f, 1530f)
            cubicTo(-100f, 1540f, -60f, 1830f, 50f, 2030f)
            lineTo(390f, 2030f)
            cubicTo(200f, 1810f, 120f, 1750f, 480f, 1630f)
            cubicTo(1150f, 1500f, 750f, 1160f, 1040f, 1170f)
            close()
        }
        paint.shader = LinearGradient(width, 1000f, 150f, height,
            intArrayOf(Color.rgb(250, 178, 120), Color.rgb(177, 78, 116), Color.rgb(78, 80, 167)), null, Shader.TileMode.CLAMP)
        canvas.drawPath(warm, paint)
        return bitmap
    }
}
