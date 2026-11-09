package com.kuzayengineering.lockbox

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.Gainmap
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Half
import android.view.View
import android.widget.ImageView
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ShortBuffer
import java.util.concurrent.Executors
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Turns a captured video frame into a JPEG.
 *
 * Input is a half-float bitmap in linear extended sRGB, where 1.0 is normal
 * ("SDR") white and anything brighter is an HDR highlight.
 *
 *  * With HDR highlights (Android 14+): an Ultra HDR JPEG - a normal
 *    picture plus a gain map that HDR screens use to restore the highlights.
 *  * Without: a normal JPEG.
 *
 * The normal picture keeps everything up to [KNEE] unchanged and smoothly
 * rolls the brighter highlights off into the remaining range, so mid-tones
 * are not darkened.
 */
object UltraHdr {
    private const val KNEE = 0.8f
    private const val EPS = 1f / 64f
    private const val BLOCK = 4 // gain map is 1/4 of the width and height
    private const val MAX_PEAK = 16f

    private val srgbLut = ByteArray(4096) { i ->
        val v = i / 4095f
        val s = if (v <= 0.0031308f) 12.92f * v else 1.055f * v.toDouble().pow(1 / 2.4).toFloat() - 0.055f
        (s * 255f).roundToInt().coerceIn(0, 255).toByte()
    }

    private fun srgb(v: Float): Int =
        srgbLut[(v.coerceIn(0f, 1f) * 4095f).toInt()].toInt() and 0xFF

    /** Highlight roll-off: identity below KNEE, maps [peak] exactly to 1. */
    private fun toneMap(l: Float, peak: Float, c: Float): Float {
        if (l <= KNEE || peak <= 1f) return min(l, 1f)
        val e = l - KNEE
        val range = peak - KNEE
        return KNEE + (1f - KNEE) * (e / (e + c)) * ((range + c) / range)
    }

    /** Linear-extended half-float copy of any bitmap. */
    fun toLinearF16(src: Bitmap): Bitmap {
        val dst = Bitmap.createBitmap(
            src.width, src.height, Bitmap.Config.RGBA_F16, false,
            ColorSpace.get(ColorSpace.Named.LINEAR_EXTENDED_SRGB),
        )
        val soft = if (src.config == Bitmap.Config.HARDWARE) src.copy(Bitmap.Config.RGBA_F16, false) else src
        Canvas(dst).drawBitmap(soft, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
        return dst
    }

    /**
     * Encodes [hdr] (RGBA_F16, linear extended sRGB). Recycles [hdr].
     * Returns null if the picture is completely black (capture failed).
     */
    fun encode(hdr: Bitmap, quality: Int = 95): ByteArray? {
        val w = hdr.width
        val h = hdr.height
        val n = w * h
        val px = ShortArray(n * 4)
        hdr.copyPixelsToBuffer(ShortBuffer.wrap(px))
        hdr.recycle()

        // Pass 1: brightest point.
        var peak = 0f
        var i = 0
        while (i < n) {
            val o = i * 4
            val l = 0.2126f * Half.toFloat(px[o]) + 0.7152f * Half.toFloat(px[o + 1]) +
                0.0722f * Half.toFloat(px[o + 2])
            if (l > peak) peak = l
            i++
        }
        if (peak < 0.01f) return null
        val useGainmap = Build.VERSION.SDK_INT >= 34 && peak > 1.05f
        peak = min(peak, MAX_PEAK)
        val range = peak - KNEE
        val c = if (peak > 1f) (1f - KNEE) * range / (range - (1f - KNEE)) else 1f

        // Pass 2: normal picture + gain per block.
        val sdr = IntArray(n)
        val gw = (w + BLOCK - 1) / BLOCK
        val gh = (h + BLOCK - 1) / BLOCK
        val logSum = if (useGainmap) FloatArray(gw * gh) else FloatArray(0)
        val count = if (useGainmap) IntArray(gw * gh) else IntArray(0)
        for (y in 0 until h) {
            val gRow = (y / BLOCK) * gw
            for (x in 0 until w) {
                val p = y * w + x
                val o = p * 4
                val r = max(0f, Half.toFloat(px[o]))
                val g = max(0f, Half.toFloat(px[o + 1]))
                val b = max(0f, Half.toFloat(px[o + 2]))
                val l = 0.2126f * r + 0.7152f * g + 0.0722f * b
                val lo = toneMap(l, peak, c)
                val s = if (l > 1e-6f) lo / l else 1f
                sdr[p] = (0xFF shl 24) or (srgb(r * s) shl 16) or (srgb(g * s) shl 8) or srgb(b * s)
                if (useGainmap) {
                    val gi = gRow + x / BLOCK
                    logSum[gi] += ln((l + EPS) / (lo + EPS))
                    count[gi]++
                }
            }
        }
        val base = Bitmap.createBitmap(sdr, w, h, Bitmap.Config.ARGB_8888)
        if (useGainmap) {
            val maxRatio = (peak + EPS) / (1f + EPS)
            val logMax = ln(maxRatio)
            val bytes = ByteArray(gw * gh)
            for (k in bytes.indices) {
                val v = if (count[k] == 0) 0f else (logSum[k] / count[k]) / logMax
                bytes[k] = (v.coerceIn(0f, 1f) * 255f).roundToInt().toByte()
            }
            if (Build.VERSION.SDK_INT >= 34) attachGainmap(base, bytes, gw, gh, maxRatio)
        }
        val out = ByteArrayOutputStream()
        base.compress(Bitmap.CompressFormat.JPEG, quality, out)
        return out.toByteArray()
    }

    @RequiresApi(34)
    private fun attachGainmap(base: Bitmap, bytes: ByteArray, gw: Int, gh: Int, maxRatio: Float) {
        val contents = Bitmap.createBitmap(gw, gh, Bitmap.Config.ALPHA_8)
        contents.copyPixelsFromBuffer(ByteBuffer.wrap(bytes))
        val gm = Gainmap(contents).apply {
            setRatioMin(1f, 1f, 1f)
            setRatioMax(maxRatio, maxRatio, maxRatio)
            setGamma(1f, 1f, 1f)
            setEpsilonSdr(EPS, EPS, EPS)
            setEpsilonHdr(EPS, EPS, EPS)
            setMinDisplayRatioForHdrTransition(1f)
            setDisplayRatioForFullHdr(maxRatio)
        }
        base.gainmap = gm
    }

    /** True if this phone can show HDR photos (Android 14+ and an HDR screen). */
    fun displayCapable(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        return try {
            activity.display?.isHdr == true
        } catch (_: Exception) {
            false
        }
    }
}

/**
 * Native photo view used for Ultra HDR photos on Android 14+, so their
 * highlights are shown in real HDR. Gestures stay in Flutter, which sends
 * the zoom/pan transform here ("lockbox/hdr" setTransform).
 */
class HdrImageFactory(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    private val views = mutableListOf<HdrImage>()
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "lockbox/hdr").setMethodCallHandler { call, result ->
            when (call.method) {
                "capable" -> result.success(UltraHdr.displayCapable(activity))
                "sdk" -> result.success(Build.VERSION.SDK_INT)
                "setTransform" -> {
                    val s = (call.argument<Number>("scale") ?: 1).toFloat()
                    val x = (call.argument<Number>("tx") ?: 0).toFloat()
                    val y = (call.argument<Number>("ty") ?: 0).toFloat()
                    views.lastOrNull()?.setTransform(s, x, y)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val bytes = (args as? Map<*, *>)?.get("bytes") as? ByteArray ?: ByteArray(0)
        val v = HdrImage(context, bytes)
        views.add(v)
        updateColorMode()
        return v
    }

    private fun updateColorMode() {
        if (Build.VERSION.SDK_INT < 26) return
        activity.window.colorMode =
            if (views.isNotEmpty()) ActivityInfo.COLOR_MODE_HDR else ActivityInfo.COLOR_MODE_DEFAULT
    }

    inner class HdrImage(context: Context, bytes: ByteArray) : PlatformView {
        private val image = ImageView(context).apply {
            scaleType = ImageView.ScaleType.MATRIX
            setBackgroundColor(Color.TRANSPARENT)
        }
        private var scale = 1f
        private var tx = 0f
        private var ty = 0f

        init {
            image.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> applyMatrix() }
            io.execute {
                val bmp = try {
                    if (Build.VERSION.SDK_INT >= 28) {
                        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { d, info, _ ->
                            val big = max(info.size.width, info.size.height)
                            if (big > 4096) {
                                val f = 4096f / big
                                d.setTargetSize((info.size.width * f).toInt(), (info.size.height * f).toInt())
                            }
                        }
                    } else {
                        null
                    }
                } catch (_: Throwable) {
                    null
                }
                main.post {
                    if (bmp != null) {
                        image.setImageBitmap(bmp)
                        applyMatrix()
                    }
                }
            }
        }

        fun setTransform(s: Float, x: Float, y: Float) {
            scale = s
            tx = x
            ty = y
            applyMatrix()
        }

        private fun applyMatrix() {
            val d = image.drawable ?: return
            val vw = image.width.toFloat()
            val vh = image.height.toFloat()
            val bw = d.intrinsicWidth.toFloat()
            val bh = d.intrinsicHeight.toFloat()
            if (vw <= 0 || vh <= 0 || bw <= 0 || bh <= 0) return
            val fit = min(vw / bw, vh / bh)
            val m = Matrix()
            m.setScale(fit, fit)
            m.postTranslate((vw - bw * fit) / 2f, (vh - bh * fit) / 2f)
            m.postScale(scale, scale)
            m.postTranslate(tx, ty)
            image.imageMatrix = m
        }

        override fun getView(): View = image

        override fun dispose() {
            views.remove(this)
            image.setImageDrawable(null)
            updateColorMode()
        }
    }
}
