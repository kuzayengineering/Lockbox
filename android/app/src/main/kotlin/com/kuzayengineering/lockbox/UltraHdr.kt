package com.kuzayengineering.lockbox

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaDataSource
import android.media.MediaExtractor
import android.media.MediaFormat
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
import java.nio.ByteOrder
import java.nio.ShortBuffer
import java.util.concurrent.Executors
import kotlin.math.exp
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
        val px = ShortArray(w * h * 4)
        hdr.copyPixelsToBuffer(ShortBuffer.wrap(px))
        hdr.recycle()
        return encodeHalfs(px, w, h, quality)
    }

    /** Same as [encode] for raw RGBA half-floats (linear extended sRGB). */
    fun encodeHalfs(px: ShortArray, w: Int, h: Int, quality: Int = 95): ByteArray? {
        val n = w * h

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
 * Decodes one video frame straight from the file in its original 10-bit
 * HDR form and converts it to linear light ourselves (Android's own frame
 * copies are converted to normal range on many phones, losing the HDR).
 *
 *  * HLG:   ITU-R BT.2100 inverse OETF + OOTF for a 1000-nit display
 *  * HDR10: SMPTE ST 2084 (PQ) EOTF
 *  * 203 nits (BT.2408 reference white) = 1.0, BT.2020 -> BT.709 primaries
 *
 * Output: RGBA half-floats, linear extended sRGB, ready for [UltraHdr].
 */
@RequiresApi(33)
object HdrFrameDecoder {
    class Frame(val px: ShortArray, val width: Int, val height: Int)

    private const val TIMEOUT_US = 10_000L
    private const val REF_WHITE = 203f
    private const val LUT = 4096

    // Scene-linear light for an HLG signal value.
    private val hlgInv = FloatArray(LUT + 1) { i ->
        val e = i.toFloat() / LUT
        if (e <= 0.5f) e * e / 3f
        else ((exp(((e - 0.55991073f) / 0.17883277f).toDouble()) + 0.28466892) / 12.0).toFloat()
    }

    // HLG system gain: 1000 nits * Ys^(1.2 - 1), relative to reference white.
    private val hlgOotf = FloatArray(LUT + 1) { i ->
        val ys = i.toFloat() / LUT
        (1000.0 * ys.toDouble().pow(0.2) / REF_WHITE).toFloat()
    }

    // Display light for a PQ signal value, relative to reference white.
    private val pqEotf = FloatArray(LUT + 1) { i ->
        val e = (i.toFloat() / LUT).toDouble()
        val m1 = 0.1593017578125; val m2 = 78.84375
        val c1 = 0.8359375; val c2 = 18.8515625; val c3 = 18.6875
        val p = e.pow(1 / m2)
        val l = (max(p - c1, 0.0) / (c2 - c3 * p)).pow(1 / m1)
        (10000.0 * l / REF_WHITE).toFloat()
    }

    private fun lut(t: FloatArray, v: Float): Float = t[(v.coerceIn(0f, 1f) * LUT).toInt()]

    /** [hint] is the HDR type Lockbox recorded for the video ("hlg", "hdr10"...). */
    fun decode(source: MediaDataSource, timeUs: Long, hint: String): Frame? {
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ex.setDataSource(source)
            var track = -1
            var fmt: MediaFormat? = null
            for (t in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(t)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    track = t
                    fmt = f
                    break
                }
            }
            val format = fmt ?: return null
            ex.selectTrack(track)
            fun int(key: String) = if (format.containsKey(key)) format.getInteger(key) else 0
            val transfer = int(MediaFormat.KEY_COLOR_TRANSFER)
            val pq = transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
                (transfer != MediaFormat.COLOR_TRANSFER_HLG && hint == "hdr10")
            val fullRange = int(MediaFormat.KEY_COLOR_RANGE) == MediaFormat.COLOR_RANGE_FULL
            val rotation = int(MediaFormat.KEY_ROTATION)
            var mime = format.getString(MediaFormat.KEY_MIME)!!
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUVP010)
            codec = try {
                MediaCodec.createDecoderByType(mime)
            } catch (e: Exception) {
                // Dolby Vision files carry an HEVC picture any phone can decode.
                if (mime != MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION) throw e
                mime = MediaFormat.MIMETYPE_VIDEO_HEVC
                format.setString(MediaFormat.KEY_MIME, mime)
                MediaCodec.createDecoderByType(mime)
            }
            codec.configure(format, null, null, 0)
            codec.start()
            ex.seekTo(timeUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            val deadline = System.currentTimeMillis() + 10_000
            while (System.currentTimeMillis() < deadline) {
                if (!inputDone) {
                    val ii = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (ii >= 0) {
                        val buf = codec.getInputBuffer(ii)!!
                        val size = ex.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(ii, 0, size, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                val oi = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (oi < 0) continue
                val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                // The frame on screen at the paused position (10 ms slack).
                if (info.size > 0 && (info.presentationTimeUs >= timeUs - 10_000 || eos)) {
                    val img = codec.getOutputImage(oi)
                    val frame = img?.let { convert(it, pq, fullRange, rotation) }
                    img?.close()
                    codec.releaseOutputBuffer(oi, false)
                    return frame
                }
                codec.releaseOutputBuffer(oi, false)
                if (eos) break
            }
            return null
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            ex.release()
        }
    }

    private fun convert(img: Image, pq: Boolean, fullRange: Boolean, rotation: Int): Frame {
        val crop = img.cropRect
        val w = crop.width()
        val h = crop.height()
        val tenBit = img.format == ImageFormat.YCBCR_P010
        val yP = img.planes[0]
        val uP = img.planes[1]
        val vP = img.planes[2]
        val yB = yP.buffer.order(ByteOrder.LITTLE_ENDIAN)
        val uB = uP.buffer.order(ByteOrder.LITTLE_ENDIAN)
        val vB = vP.buffer.order(ByteOrder.LITTLE_ENDIAN)
        fun sample(b: ByteBuffer, off: Int): Int =
            if (tenBit) (b.getShort(off).toInt() and 0xFFFF) shr 6 else (b.get(off).toInt() and 0xFF) shl 2
        val turned = rotation == 90 || rotation == 270
        val ow = if (turned) h else w
        val oh = if (turned) w else h
        val out = ShortArray(ow * oh * 4)
        val one = Half.toHalf(1f)
        for (y in 0 until h) {
            val sy = y + crop.top
            val cy = sy / 2
            for (x in 0 until w) {
                val sx = x + crop.left
                val cx = sx / 2
                val yv = sample(yB, sy * yP.rowStride + sx * yP.pixelStride)
                val uv = sample(uB, cy * uP.rowStride + cx * uP.pixelStride)
                val vv = sample(vB, cy * vP.rowStride + cx * vP.pixelStride)
                val yn: Float
                val cb: Float
                val cr: Float
                if (fullRange) {
                    yn = yv / 1023f; cb = (uv - 512) / 1023f; cr = (vv - 512) / 1023f
                } else {
                    yn = (yv - 64) / 876f; cb = (uv - 512) / 896f; cr = (vv - 512) / 896f
                }
                // BT.2020 non-constant luminance Y'CbCr -> R'G'B'
                val rp = yn + 1.4746f * cr
                val gp = yn - 0.16455f * cb - 0.57135f * cr
                val bp = yn + 1.8814f * cb
                var r: Float
                var g: Float
                var b: Float
                if (pq) {
                    r = lut(pqEotf, rp); g = lut(pqEotf, gp); b = lut(pqEotf, bp)
                } else {
                    r = lut(hlgInv, rp); g = lut(hlgInv, gp); b = lut(hlgInv, bp)
                    val gain = lut(hlgOotf, 0.2627f * r + 0.6780f * g + 0.0593f * b)
                    r *= gain; g *= gain; b *= gain
                }
                // BT.2020 -> BT.709 primaries (linear)
                val r7 = 1.6605f * r - 0.5876f * g - 0.0728f * b
                val g7 = -0.1246f * r + 1.1329f * g - 0.0083f * b
                val b7 = -0.0182f * r - 0.1006f * g + 1.1187f * b
                val o = when (rotation) {
                    90 -> (x * ow + (h - 1 - y)) * 4
                    180 -> ((h - 1 - y) * ow + (w - 1 - x)) * 4
                    270 -> ((w - 1 - x) * ow + y) * 4
                    else -> (y * ow + x) * 4
                }
                out[o] = Half.toHalf(max(0f, r7))
                out[o + 1] = Half.toHalf(max(0f, g7))
                out[o + 2] = Half.toHalf(max(0f, b7))
                out[o + 3] = one
            }
        }
        return Frame(out, ow, oh)
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
