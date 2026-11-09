package com.kuzayengineering.lockbox

import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

/**
 * Bridges Flutter to Android's ExoPlayer (Media3).
 *
 * ExoPlayer renders through a SurfaceView, so HDR10 / HLG / Dolby Vision
 * video is passed to the display in true HDR, at the full frame rate
 * (60 fps and above), using the phone's hardware decoders.
 */
@OptIn(UnstableApi::class)
class LockboxPlayer(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, Player.Listener {

    private val methods = MethodChannel(messenger, "lockbox/player")
    private val events = EventChannel(messenger, "lockbox/player/events")
    private var sink: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())
    private var player: ExoPlayer? = null
    private val views = mutableSetOf<PlayerView>()
    private var ticking = false

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    private val ticker = object : Runnable {
        override fun run() {
            sendState()
            if (player?.isPlaying == true) {
                handler.postDelayed(this, 200)
            } else {
                ticking = false
            }
        }
    }

    fun ensurePlayer(): ExoPlayer {
        player?.let { return it }
        val renderers = DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
        val p = ExoPlayer.Builder(context, renderers).build()
        p.setAudioAttributes(AudioAttributes.DEFAULT, /* handleAudioFocus= */ true)
        p.setHandleAudioBecomingNoisy(true)
        p.addListener(this)
        player = p
        views.forEach { it.player = p }
        return p
    }

    fun attachView(view: PlayerView) {
        views.add(view)
        view.player = ensurePlayer()
    }

    fun detachView(view: PlayerView) {
        views.remove(view)
        view.player = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> {
                    val path = call.argument<String>("path")!!
                    val key = call.argument<ByteArray>("key")!!
                    val p = ensurePlayer()
                    val file = File(path)
                    val factory = DataSource.Factory { EncryptedBlobDataSource(file, key) }
                    val source = ProgressiveMediaSource.Factory(factory)
                        .createMediaSource(MediaItem.fromUri(Uri.fromFile(file)))
                    p.setMediaSource(source)
                    p.repeatMode = if (call.argument<Boolean>("loop") == true)
                        Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
                    p.volume = if (call.argument<Boolean>("muted") == true) 0f else 1f
                    p.setPlaybackParameters(PlaybackParameters(1f))
                    p.prepare()
                    p.playWhenReady = call.argument<Boolean>("autoplay") ?: true
                    sendState()
                    result.success(null)
                }
                "play" -> {
                    val p = ensurePlayer()
                    if (p.playbackState == Player.STATE_ENDED) p.seekTo(0)
                    p.play()
                    result.success(null)
                }
                "pause" -> { player?.pause(); result.success(null) }
                "seek" -> {
                    val ms = (call.argument<Number>("ms") ?: 0).toLong()
                    player?.seekTo(ms)
                    sendState()
                    result.success(null)
                }
                // Scrubbing mode: the player is tuned for many rapid seeks so
                // frames update in real time while the scrub bar is dragged.
                "scrubStart" -> {
                    val p = ensurePlayer()
                    p.setScrubbingModeEnabled(true)
                    result.success(null)
                }
                "scrubEnd" -> {
                    player?.setScrubbingModeEnabled(false)
                    sendState()
                    result.success(null)
                }
                "speed" -> {
                    val s = (call.argument<Number>("speed") ?: 1.0).toFloat()
                    player?.setPlaybackParameters(PlaybackParameters(s))
                    result.success(null)
                }
                "volume" -> {
                    player?.volume = (call.argument<Number>("volume") ?: 1.0).toFloat()
                    result.success(null)
                }
                "loop" -> {
                    player?.repeatMode = if (call.argument<Boolean>("loop") == true)
                        Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
                    result.success(null)
                }
                "stop" -> {
                    player?.stop()
                    player?.clearMediaItems()
                    result.success(null)
                }
                "release" -> {
                    release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("player", e.message, null)
        }
    }

    fun release() {
        views.forEach { it.player = null }
        player?.removeListener(this)
        player?.release()
        player = null
    }

    private fun startTicking() {
        if (!ticking) {
            ticking = true
            handler.post(ticker)
        }
    }

    private fun sendState(error: String? = null) {
        val p = player ?: return
        val size: VideoSize = p.videoSize
        val duration = p.duration
        val state = hashMapOf<String, Any?>(
            "position" to p.currentPosition,
            "duration" to if (duration == C.TIME_UNSET) 0L else duration,
            "buffered" to p.bufferedPosition,
            "playing" to p.isPlaying,
            "buffering" to (p.playbackState == Player.STATE_BUFFERING),
            "ended" to (p.playbackState == Player.STATE_ENDED),
            "width" to size.width,
            "height" to size.height,
            "volume" to p.volume.toDouble(),
            "speed" to p.playbackParameters.speed.toDouble(),
            "error" to error,
        )
        sink?.success(state)
    }

    // Player.Listener
    override fun onIsPlayingChanged(isPlaying: Boolean) {
        views.forEach { it.keepScreenOn = isPlaying }
        if (isPlaying) startTicking()
        sendState()
    }

    override fun onPlaybackStateChanged(playbackState: Int) = sendState()
    override fun onVideoSizeChanged(videoSize: VideoSize) = sendState()
    override fun onPlayerError(error: PlaybackException) =
        sendState(error.errorCodeName + ": " + (error.message ?: ""))

    // EventChannel.StreamHandler
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        sendState()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}

/** Creates the native video surface that Flutter embeds in the viewer. */
@OptIn(UnstableApi::class)
class PlayerViewFactory(private val player: LockboxPlayer) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val view = PlayerView(context).apply {
            useController = false
            setShutterBackgroundColor(Color.BLACK)
            setBackgroundColor(Color.BLACK)
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            setKeepContentOnPlayerReset(false)
        }
        player.attachView(view)
        return object : PlatformView {
            override fun getView(): View = view
            override fun dispose() = player.detachView(view)
        }
    }
}
