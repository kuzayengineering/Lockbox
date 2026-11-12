package com.kuzayengineering.lockbox

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import androidx.media3.datasource.DataSourceInputStream
import androidx.media3.datasource.DataSpec
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max

class MainActivity : FlutterActivity() {

    private var player: LockboxPlayer? = null
    private var nativeChannel: MethodChannel? = null
    private var compressor: VideoCompressor? = null
    private val io = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val pending = HashMap<Int, (Intent?) -> Unit>()
    private val nextRequest = AtomicInteger(4000)

    /** Files opened for import, by handle id. */
    /**
     * A picked file opened for Dart. [path] is either "/proc/self/fd/N" (read
     * the original directly, no copy) or a temporary copy in the app's private
     * cache when Android doesn't allow the direct route for that storage.
     * [writeBack]: temporary file to be copied to [uri] when closed (backups).
     */
    private class ImportHandle(
        val uri: Uri,
        val pfd: ParcelFileDescriptor?,
        val temp: File?,
        val path: String,
        val writeBack: Boolean = false,
    )

    /** Can Dart open this "/proc/self/fd" path? Some storage providers refuse. */
    private fun canOpen(path: String, forWrite: Boolean): Boolean = try {
        if (forWrite) FileOutputStream(File(path), true).close() else FileInputStream(File(path)).use { it.read() }
        true
    } catch (_: Exception) {
        false
    }
    private val imports = HashMap<Int, ImportHandle>()
    private val nextHandle = AtomicInteger(1)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Block screenshots / screen recording / casting and hide content in
        // the recent-apps switcher. Always on: nothing in Lockbox is shareable.
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        // Volume buttons always control media volume in Lockbox (not the
        // ringer), even when nothing is playing at that moment.
        volumeControlStream = AudioManager.STREAM_MUSIC
        // Recent-apps switcher shows no picture of Lockbox at all.
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
    }

    /** Leaving the screen (home, recents, other app, screen off): lock now. */
    override fun onPause() {
        super.onPause()
        nativeChannel?.invokeMethod("paused", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val p = LockboxPlayer(applicationContext, messenger)
        player = p
        flutterEngine.platformViewsController.registry
            .registerViewFactory("lockbox/video_view", PlayerViewFactory(p))
        flutterEngine.platformViewsController.registry
            .registerViewFactory("lockbox/hdr_image", HdrImageFactory(this, messenger))
        compressor = VideoCompressor(this, messenger)
        nativeChannel = MethodChannel(messenger, "lockbox/native")
        nativeChannel!!.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Exception) {
                result.error("native", e.message, null)
            }
        }
    }

    override fun onDestroy() {
        compressor?.cancel()
        player?.release()
        imports.values.forEach { closeHandle(it, false) }
        imports.clear()
        super.onDestroy()
    }

    // ------------------------------------------------------------ helpers

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("native", e.message, null) }
            }
        }
    }

    private fun launch(intent: Intent, onResult: (Intent?) -> Unit) {
        val code = nextRequest.incrementAndGet()
        pending[code] = onResult
        @Suppress("DEPRECATION")
        startActivityForResult(intent, code)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val cb = pending.remove(requestCode)
        if (cb != null) {
            cb(if (resultCode == Activity.RESULT_OK) data else null)
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun describe(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size: Long? = null
        var modified: Long? = null
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val si = c.getColumnIndex(OpenableColumns.SIZE)
                val mi = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                if (ni >= 0) name = c.getString(ni)
                if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                if (mi >= 0 && !c.isNull(mi)) modified = c.getLong(mi).takeIf { it > 0 }
            }
        }
        return mapOf(
            "uri" to uri.toString(),
            "name" to (name ?: uri.lastPathSegment ?: "file"),
            "size" to size,
            "mime" to contentResolver.getType(uri),
            "relativePath" to originalFolder(uri),
            "modified" to modified,
        )
    }

    /**
     * Works out which shared-storage folder a picked file lives in, e.g.
     * "DCIM/Camera/", so it can be put back there when restored.
     */
    private fun originalFolder(uri: Uri): String? {
        try {
            if (DocumentsContract.isDocumentUri(this, uri) &&
                uri.authority == "com.android.externalstorage.documents") {
                // Document id looks like "primary:DCIM/Camera/IMG_1.jpg"
                val id = DocumentsContract.getDocumentId(uri)
                val rel = id.substringAfter(':', "")
                val slash = rel.lastIndexOf('/')
                return if (slash > 0) rel.substring(0, slash + 1) else ""
            }
            val mediaUri = try { MediaStore.getMediaUri(this, uri) } catch (_: Exception) { null } ?: uri
            contentResolver.query(mediaUri, arrayOf(MediaStore.MediaColumns.RELATIVE_PATH), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val i = c.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                    if (i >= 0) return c.getString(i)
                }
            }
        } catch (_: Exception) {}
        return null
    }

    /**
     * Puts a restored file back into shared storage through MediaStore, in
     * [relativePath] (e.g. "DCIM/Camera/"). Falls back to the Download
     * folder if Android doesn't allow that folder for this file type.
     * Returns the folder actually used.
     */
    /**
     * The bytes to write: either a plain file ("src") or a Lockbox encrypted
     * file ("blob" + "key") that is decrypted on the fly, so no decrypted
     * temporary copy is ever written.
     */
    @androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])
    private fun inputFor(call: MethodCall): () -> InputStream {
        val blob = call.argument<String>("blob")
        if (blob != null) {
            val key = call.argument<ByteArray>("key")!!
            return {
                val file = File(blob)
                DataSourceInputStream(EncryptedBlobDataSource(file, key), DataSpec(Uri.fromFile(file)))
            }
        }
        val src = call.argument<String>("src")!!
        return { FileInputStream(src) }
    }

    private fun restoreToMediaStore(input: () -> InputStream, name: String, mime: String, kind: String, relativePath: String): String {
        val volume = MediaStore.VOLUME_EXTERNAL_PRIMARY
        val primary = when (kind) {
            "photo" -> MediaStore.Images.Media.getContentUri(volume)
            "video" -> MediaStore.Video.Media.getContentUri(volume)
            "audio" -> MediaStore.Audio.Media.getContentUri(volume)
            // Documents and other files: Documents/ or Download/ folders.
            else -> MediaStore.Files.getContentUri(volume)
        }
        val attempts = listOf(
            primary to relativePath,
            MediaStore.Downloads.getContentUri(volume) to relativePath,
            MediaStore.Downloads.getContentUri(volume) to "Download/Lockbox/",
        )
        var lastError: Exception? = null
        for ((collection, rel) in attempts) {
            var item: Uri? = null
            try {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                item = contentResolver.insert(collection, values) ?: continue
                contentResolver.openOutputStream(item)!!.use { out ->
                    input().use { it.copyTo(out, 1 shl 20) }
                }
                contentResolver.update(item, ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }, null, null)
                return rel
            } catch (e: Exception) {
                lastError = e
                item?.let { try { contentResolver.delete(it, null, null) } catch (_: Exception) {} }
            }
        }
        throw lastError ?: IllegalStateException("Could not restore $name")
    }

    private fun closeHandle(h: ImportHandle, deleteOriginal: Boolean): Boolean {
        try { h.pfd?.close() } catch (_: Exception) {}
        if (h.writeBack && h.temp != null) {
            try {
                contentResolver.openOutputStream(h.uri, "wt")!!.use { out ->
                    FileInputStream(h.temp).use { it.copyTo(out, 1 shl 20) }
                }
            } finally {
                h.temp.delete()
            }
            return true
        }
        h.temp?.delete()
        if (!deleteOriginal) return false
        return try {
            DocumentsContract.deleteDocument(contentResolver, h.uri)
        } catch (_: Exception) {
            false
        }
    }

    private fun jpeg(bitmap: Bitmap, quality: Int = 82): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        return out.toByteArray()
    }

    private fun scaled(b: Bitmap, maxSide: Int): Bitmap {
        val s = maxSide.toFloat() / max(b.width, b.height)
        if (s >= 1f) return b
        return Bitmap.createScaledBitmap(b, (b.width * s).toInt().coerceAtLeast(1), (b.height * s).toInt().coerceAtLeast(1), true)
    }

    @androidx.annotation.RequiresApi(28)
    private fun decodeImageSource(source: ImageDecoder.Source, maxSide: Int): Bitmap =
        ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val w = info.size.width
            val h = info.size.height
            val s = maxSide.toFloat() / max(w, h)
            if (s < 1f) decoder.setTargetSize((w * s).toInt().coerceAtLeast(1), (h * s).toInt().coerceAtLeast(1))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }

    // ------------------------------------------------------------ methods

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // "Save frame": full-resolution still from an encrypted video.
            // Video gestures: media volume and screen brightness (0..1).
            "getMediaVolume" -> {
                val am = getSystemService(AUDIO_SERVICE) as AudioManager
                val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                result.success(am.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max)
            }
            "setMediaVolume" -> {
                val am = getSystemService(AUDIO_SERVICE) as AudioManager
                val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                val v = (call.argument<Number>("value") ?: 0).toDouble().coerceIn(0.0, 1.0)
                am.setStreamVolume(AudioManager.STREAM_MUSIC, Math.round(v * max).toInt(), 0)
                result.success(null)
            }
            "getBrightness" -> {
                val own = window.attributes.screenBrightness
                val v = if (own >= 0f) own.toDouble() else try {
                    Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255.0
                } catch (_: Exception) {
                    0.5
                }
                result.success(v)
            }
            "setBrightness" -> {
                val v = (call.argument<Number>("value") ?: 0.5).toFloat().coerceIn(0.01f, 1f)
                window.attributes = window.attributes.apply { screenBrightness = v }
                result.success(null)
            }
            "resetBrightness" -> {
                window.attributes = window.attributes.apply {
                    screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                }
                result.success(null)
            }

            "grabFrame" -> {
                val blob = call.argument<String>("blob")!!
                val key = call.argument<ByteArray>("key")!!
                val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                val wantHdr = call.argument<Boolean>("hdr") == true && Build.VERSION.SDK_INT >= 34
                val hint = call.argument<String>("transfer") ?: "hlg"
                background(result) {
                    // HDR video: decode the original 10-bit frame and save it
                    // as an Ultra HDR photo.
                    UltraHdr.lastNote = ""
                    if (wantHdr) {
                        val ds = EncryptedMediaDataSource(File(blob), key)
                        try {
                            val f = HdrFrameDecoder.decode(ds, positionMs * 1000, hint)
                            if (f == null) {
                                UltraHdr.lastNote = "the HDR frame could not be decoded"
                            } else {
                                val bytes = UltraHdr.encodeHalfs(f.px, f.width, f.height)
                                if (bytes != null) return@background bytes
                            }
                        } catch (e: Throwable) {
                            UltraHdr.lastNote = "HDR decode failed: ${e.message ?: e.javaClass.simpleName}"
                        } finally {
                            try { ds.close() } catch (_: Exception) {}
                        }
                    }
                    // The phone's video decoder can be briefly busy (the
                    // player is using one too), so try a few times.
                    var lastError: Exception? = null
                    for (attempt in 1..3) {
                        val ds = EncryptedMediaDataSource(File(blob), key)
                        val r = MediaMetadataRetriever()
                        try {
                            r.setDataSource(ds)
                            val bmp = r.getFrameAtTime(positionMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
                            if (bmp != null) return@background jpeg(bmp, 95)
                            lastError = IllegalStateException("the decoder returned no picture")
                        } catch (e: Exception) {
                            lastError = e
                        } finally {
                            try { r.release() } catch (_: Exception) {}
                            try { ds.close() } catch (_: Exception) {}
                        }
                        Thread.sleep(250L * attempt)
                    }
                    throw lastError ?: IllegalStateException("unknown error")
                }
            }

            // Opens the system picker (any kind of file).
            "pickMedia" -> {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*" // any kind of file
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
                launch(intent) { data ->
                    if (data == null) { result.success(emptyList<Any>()); return@launch }
                    val uris = mutableListOf<Uri>()
                    val clip = data.clipData
                    if (clip != null) {
                        for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
                    } else {
                        data.data?.let { uris.add(it) }
                    }
                    background(result) { uris.map { describe(it) } }
                }
            }

            "pickFile" -> {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }
                launch(intent) { data ->
                    val uri = data?.data
                    if (uri == null) result.success(null) else background(result) { describe(uri) }
                }
            }

            // Makes a picked file readable by Dart as a normal file path.
            "openImport" -> {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                background(result) {
                    var pfd: ParcelFileDescriptor? = null
                    try {
                        pfd = contentResolver.openFileDescriptor(uri, "r")
                    } catch (_: Exception) {}
                    val direct = pfd != null && pfd.statSize >= 0 &&
                        canOpen("/proc/self/fd/${pfd.fd}", forWrite = false)
                    val handle: ImportHandle = if (direct) {
                        ImportHandle(uri, pfd, null, "/proc/self/fd/${pfd!!.fd}")
                    } else {
                        try { pfd?.close() } catch (_: Exception) {}
                        // Direct reading isn't allowed for this storage (or it's a
                        // cloud file): copy into private cache; deleted when closed.
                        val tmp = File.createTempFile("import", ".bin", cacheDir)
                        contentResolver.openInputStream(uri)!!.use { input ->
                            tmp.outputStream().use { input.copyTo(it, 1 shl 20) }
                        }
                        ImportHandle(uri, null, tmp, tmp.absolutePath)
                    }
                    val id = nextHandle.incrementAndGet()
                    synchronized(imports) { imports[id] = handle }
                    mapOf("handle" to id, "path" to handle.path)
                }
            }

            "closeImport" -> {
                val id = call.argument<Int>("handle")!!
                val delete = call.argument<Boolean>("deleteOriginal") == true
                val h = synchronized(imports) { imports.remove(id) }
                if (h == null) result.success(false) else background(result) { closeHandle(h, delete) }
            }

            // Reads metadata and makes a thumbnail with Android's own decoders.
            "probe" -> {
                val id = call.argument<Int>("handle")!!
                val kind = call.argument<String>("kind")!!
                val thumbSize = call.argument<Int>("thumbSize") ?: 512
                val h = synchronized(imports) { imports[id] }
                if (h == null) { result.error("native", "unknown handle", null); return }
                background(result) { probe(h, kind, thumbSize) }
            }

            // Converts image bytes Flutter can't decode (e.g. some HEIC) to JPEG.
            "toJpeg" -> {
                val bytes = call.argument<ByteArray>("bytes")!!
                val maxSide = call.argument<Int>("maxSide") ?: 4096
                background(result) {
                    val bmp = if (Build.VERSION.SDK_INT >= 28) {
                        decodeImageSource(ImageDecoder.createSource(java.nio.ByteBuffer.wrap(bytes)), maxSide)
                    } else {
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let { scaled(it, maxSide) }
                    }
                    bmp?.let { jpeg(it, 92) }
                }
            }

            // Lets the user pick a folder, then writes decrypted exports there.
            "pickFolder" -> {
                val persist = call.argument<Boolean>("persist") == true
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }
                launch(intent) { data ->
                    val uri = data?.data
                    if (uri != null && persist) {
                        try {
                            contentResolver.takePersistableUriPermission(uri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        } catch (_: Exception) {}
                    }
                    result.success(uri?.toString())
                }
            }

            "restoreToMediaStore" -> {
                val input = inputFor(call)
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                val kind = call.argument<String>("kind") ?: "other"
                val rel = call.argument<String>("relativePath")!!
                background(result) { restoreToMediaStore(input, name, mime, kind, rel) }
            }

            "writeToFolder" -> {
                val tree = Uri.parse(call.argument<String>("tree")!!)
                val input = inputFor(call)
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                background(result) {
                    val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                    val doc = DocumentsContract.createDocument(contentResolver, parent, mime, name)
                        ?: throw IllegalStateException("Could not create $name")
                    contentResolver.openOutputStream(doc)!!.use { out ->
                        input().use { it.copyTo(out, 1 shl 20) }
                    }
                    true
                }
            }

            // "Save as" dialog that returns a writable path (used for backups,
            // so the backup is written straight to its destination).
            "createForWrite" -> {
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                launch(intent) { data ->
                    val uri = data?.data
                    if (uri == null) { result.success(null); return@launch }
                    background(result) {
                        val pfd = contentResolver.openFileDescriptor(uri, "wt")
                            ?: throw IllegalStateException("Cannot write there")
                        val direct = canOpen("/proc/self/fd/${pfd.fd}", forWrite = true)
                        val handle = if (direct) {
                            ImportHandle(uri, pfd, null, "/proc/self/fd/${pfd.fd}")
                        } else {
                            // Write to private cache first, copy over when closed.
                            try { pfd.close() } catch (_: Exception) {}
                            val tmp = File.createTempFile("backup", ".lockbox", cacheDir)
                            ImportHandle(uri, null, tmp, tmp.absolutePath, writeBack = true)
                        }
                        val id = nextHandle.incrementAndGet()
                        synchronized(imports) { imports[id] = handle }
                        mapOf("handle" to id, "path" to handle.path)
                    }
                }
            }

            // "Save as" dialog for a single file.
            "saveAs" -> {
                val src = call.argument<String>("src")!!
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                launch(intent) { data ->
                    val uri = data?.data
                    if (uri == null) { result.success(false); return@launch }
                    background(result) {
                        contentResolver.openOutputStream(uri, "wt")!!.use { out ->
                            FileInputStream(src).use { it.copyTo(out, 1 shl 20) }
                        }
                        true
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun probe(h: ImportHandle, kind: String, thumbSize: Int): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        if (kind == "photo") {
            try {
                val bmp = if (Build.VERSION.SDK_INT >= 28) {
                    decodeImageSource(ImageDecoder.createSource(contentResolver, h.uri), thumbSize)
                } else {
                    val opts = BitmapFactory.Options().apply { inSampleSize = 4 }
                    contentResolver.openInputStream(h.uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
                        ?.let { scaled(it, thumbSize) }
                }
                if (bmp != null) out["thumbnail"] = jpeg(bmp)
            } catch (_: Exception) {}
            return out
        }
        val r = MediaMetadataRetriever()
        try {
            if (h.pfd != null) r.setDataSource(h.pfd.fileDescriptor) else r.setDataSource(h.path)
            fun key(k: Int): String? = try { r.extractMetadata(k) } catch (_: Exception) { null }
            out["durationMs"] = key(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            out["date"] = key(MediaMetadataRetriever.METADATA_KEY_DATE)
            out["mime"] = key(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
            if (kind == "video") {
                out["width"] = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
                out["height"] = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
                out["rotation"] = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()
                out["captureFps"] = key(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toDoubleOrNull()
                if (Build.VERSION.SDK_INT >= 28) {
                    out["frameCount"] = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toLongOrNull()
                }
                if (Build.VERSION.SDK_INT >= 30) {
                    // MediaFormat.COLOR_TRANSFER_*: 6 = PQ (HDR10), 7 = HLG
                    out["colorTransfer"] = key(MediaMetadataRetriever.METADATA_KEY_COLOR_TRANSFER)?.toIntOrNull()
                }
                val frame = if (Build.VERSION.SDK_INT >= 27) {
                    r.getScaledFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, thumbSize, thumbSize)
                } else {
                    r.getFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)?.let { scaled(it, thumbSize) }
                } ?: r.frameAtTime?.let { scaled(it, thumbSize) }
                if (frame != null) out["thumbnail"] = jpeg(frame)
            } else {
                out["title"] = key(MediaMetadataRetriever.METADATA_KEY_TITLE)
                out["artist"] = key(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                r.embeddedPicture?.let { art ->
                    BitmapFactory.decodeByteArray(art, 0, art.size)?.let { out["thumbnail"] = jpeg(scaled(it, thumbSize)) }
                }
            }
        } catch (_: Exception) {
        } finally {
            try { r.release() } catch (_: Exception) {}
        }
        return out
    }
}
