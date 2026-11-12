package com.kuzayengineering.lockbox

import android.app.Activity
import android.media.MediaCodecInfo
import android.net.Uri
import android.view.WindowManager
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Clock
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultAssetLoaderFactory
import androidx.media3.transformer.DefaultDecoderFactory
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Makes a smaller copy of a vault video ("Make smaller copy").
 *
 * Reads the encrypted file directly (EncryptedBlobDataSource), re-encodes it
 * with the phone's hardware encoder (H.265, variable bit rate) at the chosen
 * size / frame rate / bit rate, and writes an MP4 into Lockbox's private
 * cache. Dart then encrypts it into the vault and deletes the cache file.
 */
@OptIn(UnstableApi::class)
class VideoCompressor(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "lockbox/compress")
    private var transformer: Transformer? = null
    private var pending: MethodChannel.Result? = null
    private var outFile: File? = null

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> start(call, result)
                    "progress" -> {
                        val t = transformer
                        if (t == null) {
                            result.success(-1)
                        } else {
                            val h = ProgressHolder()
                            val state = t.getProgress(h)
                            result.success(if (state == Transformer.PROGRESS_STATE_AVAILABLE) h.progress else -1)
                        }
                    }
                    "cancel" -> {
                        cancel()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("compress", e.message, null)
            }
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (transformer != null) {
            result.error("busy", "Another video is already being converted", null)
            return
        }
        val blob = File(call.argument<String>("blob")!!)
        val key = call.argument<ByteArray>("key")!!
        val shortSide = call.argument<Int>("shortSide") ?: 0 // 0 = keep
        val fps = (call.argument<Number>("fps") ?: 0).toFloat() // 0 = keep
        val bitrate = call.argument<Int>("bitrate")!!
        val keepHdr = call.argument<Boolean>("keepHdr") != false

        val out = File(activity.cacheDir, "smaller-${System.nanoTime()}.mp4")
        outFile = out

        val dataSources = DataSource.Factory { EncryptedBlobDataSource(blob, key) }
        val assetLoader = DefaultAssetLoaderFactory(
            activity,
            DefaultDecoderFactory.Builder(activity).build(),
            Clock.DEFAULT,
            ProgressiveMediaSource.Factory(dataSources),
            DataSourceBitmapLoader(activity),
        )
        val encoder = DefaultEncoderFactory.Builder(activity)
            .setRequestedVideoEncoderSettings(
                VideoEncoderSettings.Builder()
                    .setBitrate(bitrate)
                    .setBitrateMode(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                    .build()
            )
            .setEnableFallback(true)
            .build()

        val effects = mutableListOf<Effect>()
        if (shortSide > 0) effects.add(Presentation.createForShortSide(shortSide))
        if (fps > 0f) effects.add(FrameDropEffect.createDefaultFrameDropEffect(fps))
        val edited = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(blob)))
            .setEffects(Effects(emptyList(), effects))
            .build()
        val composition = Composition.Builder(EditedMediaItemSequence.Builder(edited).build())
            .setHdrMode(
                if (keepHdr) Composition.HDR_MODE_KEEP_HDR
                else Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
            )
            .build()

        val t = Transformer.Builder(activity)
            .setVideoMimeType(MimeTypes.VIDEO_H265)
            .setEncoderFactory(encoder)
            .setAssetLoaderFactory(assetLoader)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    finish {
                        it.success(
                            mapOf(
                                "path" to out.absolutePath,
                                "size" to out.length(),
                                "width" to exportResult.width,
                                "height" to exportResult.height,
                                "durationMs" to exportResult.approximateDurationMs,
                            )
                        )
                    }
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    out.delete()
                    finish {
                        it.error("compress", exportException.errorCodeName + ": " + (exportException.message ?: ""), null)
                    }
                }
            })
            .build()
        transformer = t
        pending = result
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        t.start(composition, out.absolutePath)
    }

    private fun finish(reply: (MethodChannel.Result) -> Unit) {
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        transformer = null
        outFile = null
        val r = pending
        pending = null
        r?.let(reply)
    }

    fun cancel() {
        val t = transformer ?: return
        t.cancel()
        val out = outFile
        finish { it.error("cancelled", "Cancelled", null) }
        out?.delete()
    }
}
