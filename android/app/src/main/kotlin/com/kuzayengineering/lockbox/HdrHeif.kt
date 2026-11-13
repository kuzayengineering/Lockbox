package com.kuzayengineering.lockbox

import android.graphics.ImageDecoder
import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaDataSource
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import androidx.annotation.RequiresApi
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.max

/**
 * "Save frame" as a 10-bit HDR HEIF photo: the paused frame is taken from the
 * video in its original 10-bit form (no brightness or colour conversion),
 * re-encoded as a single high-quality HEVC Main10 picture labelled with the
 * video's own colour information (e.g. BT.2020 HLG) and stored in a HEIF
 * container - one frame of the video, as a photo.
 */
@RequiresApi(33)
object HdrHeif {
    private const val TIMEOUT_US = 10_000L

    /** 10-bit frame copied out of the decoder (P010: Y plane, then interleaved UV). */
    private class Frame(
        val width: Int, val height: Int, val y: ShortArray, val uv: ShortArray,
        val transfer: Int, val standard: Int, val range: Int, val rotation: Int,
    )

    class Result(val heif: ByteArray, val thumbnail: ByteArray?, val width: Int, val height: Int, val note: String)

    fun saveFrame(source: MediaDataSource, timeUs: Long, cache: File): Result {
        val frame = decodeFrame(source, timeUs) ?: throw IllegalStateException("the 10-bit frame could not be decoded")
        val out = File.createTempFile("frame", ".heic", cache)
        try {
            encode(frame, out)
            val bytes = out.readBytes()
            // Check the photo opens, and make a small normal thumbnail.
            var info = ""
            val thumb = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { d, i, _ ->
                val big = max(i.size.width, i.size.height)
                val f = 512f / big
                d.setTargetSize((i.size.width * f).toInt().coerceAtLeast(1), (i.size.height * f).toInt().coerceAtLeast(1))
                d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                info = i.colorSpace?.name ?: ""
            }.let { bmp ->
                val o = ByteArrayOutputStream()
                val sdr = bmp.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
                sdr.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, o)
                o.toByteArray()
            }
            val turned = frame.rotation == 90 || frame.rotation == 270
            val label = when (frame.transfer) {
                MediaFormat.COLOR_TRANSFER_HLG -> "10-bit HLG"
                MediaFormat.COLOR_TRANSFER_ST2084 -> "10-bit HDR10"
                else -> "10-bit"
            }
            return Result(
                bytes, thumb,
                if (turned) frame.height else frame.width,
                if (turned) frame.width else frame.height,
                if (info.isEmpty()) label else "$label, $info",
            )
        } finally {
            out.delete()
        }
    }

    private fun decodeFrame(source: MediaDataSource, timeUs: Long): Frame? {
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ex.setDataSource(source)
            var track = -1
            var fmt: MediaFormat? = null
            for (t in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(t)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    track = t; fmt = f; break
                }
            }
            val format = fmt ?: return null
            ex.selectTrack(track)
            fun int(key: String, def: Int) = if (format.containsKey(key)) format.getInteger(key) else def
            val transfer = int(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_HLG)
            val standard = int(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT2020)
            val range = int(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            val rotation = int(MediaFormat.KEY_ROTATION, 0)
            var mime = format.getString(MediaFormat.KEY_MIME)!!
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUVP010)
            codec = try {
                MediaCodec.createDecoderByType(mime)
            } catch (e: Exception) {
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
                        val size = ex.readSampleData(codec.getInputBuffer(ii)!!, 0)
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
                if (info.size > 0 && (info.presentationTimeUs >= timeUs - 10_000 || eos)) {
                    val img = codec.getOutputImage(oi)
                    val frame = img?.let { copy(it, transfer, standard, range, rotation) }
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

    private fun copy(img: Image, transfer: Int, standard: Int, range: Int, rotation: Int): Frame {
        if (img.format != ImageFormat.YCBCR_P010) throw IllegalStateException("the decoder did not give a 10-bit picture")
        val crop = img.cropRect
        val w = crop.width() and 1.inv()
        val h = crop.height() and 1.inv()
        val yP = img.planes[0]; val uP = img.planes[1]; val vP = img.planes[2]
        val y = ShortArray(w * h)
        val uv = ShortArray(w * h / 2)
        for (r in 0 until h) {
            val row = (r + crop.top) * yP.rowStride
            for (c in 0 until w) y[r * w + c] = yP.buffer.getShort(row + (c + crop.left) * yP.pixelStride)
        }
        for (r in 0 until h / 2) {
            val sr = r + crop.top / 2
            for (c in 0 until w / 2) {
                val sc = c + crop.left / 2
                uv[r * w + c * 2] = uP.buffer.getShort(sr * uP.rowStride + sc * uP.pixelStride)
                uv[r * w + c * 2 + 1] = vP.buffer.getShort(sr * vP.rowStride + sc * vP.pixelStride)
            }
        }
        return Frame(w, h, y, uv, transfer, standard, range, rotation)
    }

    private fun encode(f: Frame, out: File) {
        val mime = MediaFormat.MIMETYPE_VIDEO_HEVC
        val format = MediaFormat.createVideoFormat(mime, f.width, f.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUVP010)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10)
            setInteger(MediaFormat.KEY_BIT_RATE, (f.width * f.height * 3).coerceAtLeast(2_000_000))
            setInteger(MediaFormat.KEY_FRAME_RATE, 1)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 0)
            // The video's own colour description, unchanged.
            setInteger(MediaFormat.KEY_COLOR_STANDARD, f.standard)
            setInteger(MediaFormat.KEY_COLOR_TRANSFER, f.transfer)
            setInteger(MediaFormat.KEY_COLOR_RANGE, f.range)
        }
        val codec = MediaCodec.createEncoderByType(mime)
        var muxer: MediaMuxer? = null
        var track = -1
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            // Hand the frame to the encoder.
            val ii = codec.dequeueInputBuffer(2_000_000)
            if (ii < 0) throw IllegalStateException("the encoder is busy")
            val img = codec.getInputImage(ii) ?: throw IllegalStateException("no encoder input picture")
            val yP = img.planes[0]; val uP = img.planes[1]; val vP = img.planes[2]
            for (r in 0 until f.height) {
                for (c in 0 until f.width) yP.buffer.putShort(r * yP.rowStride + c * yP.pixelStride, f.y[r * f.width + c])
            }
            for (r in 0 until f.height / 2) {
                for (c in 0 until f.width / 2) {
                    uP.buffer.putShort(r * uP.rowStride + c * uP.pixelStride, f.uv[r * f.width + c * 2])
                    vP.buffer.putShort(r * vP.rowStride + c * vP.pixelStride, f.uv[r * f.width + c * 2 + 1])
                }
            }
            codec.queueInputBuffer(ii, 0, f.width * f.height * 3, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)

            val info = MediaCodec.BufferInfo()
            val deadline = System.currentTimeMillis() + 15_000
            var wrote = false
            while (System.currentTimeMillis() < deadline) {
                val oi = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val of = codec.outputFormat
                    of.setString(MediaFormat.KEY_MIME, MediaFormat.MIMETYPE_IMAGE_ANDROID_HEIC)
                    of.setInteger(MediaFormat.KEY_WIDTH, f.width)
                    of.setInteger(MediaFormat.KEY_HEIGHT, f.height)
                    muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_HEIF)
                    muxer.setOrientationHint(f.rotation)
                    track = muxer.addTrack(of)
                    muxer.start()
                    continue
                }
                if (oi < 0) continue
                val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                if (!isConfig && info.size > 0 && muxer != null) {
                    val buf = codec.getOutputBuffer(oi)!!
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    info.presentationTimeUs = 0
                    muxer.writeSampleData(track, buf, info)
                    wrote = true
                }
                val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                codec.releaseOutputBuffer(oi, false)
                if (eos || wrote) break
            }
            if (!wrote) throw IllegalStateException("the encoder produced no picture")
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            codec.release()
            try { muxer?.stop() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
        }
    }
}
