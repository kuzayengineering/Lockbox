package com.kuzayengineering.lockbox

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.min

/**
 * Lets ExoPlayer read a Lockbox encrypted file directly, decrypting only the
 * chunks it needs. No decrypted copy ever touches the disk.
 *
 * Must match lib/core/blob_format.dart exactly.
 */
@OptIn(UnstableApi::class)
class EncryptedBlobDataSource(
    private val file: File,
    fileKey: ByteArray,
) : BaseDataSource(/* isNetwork= */ false) {

    companion object {
        const val HEADER_LENGTH = 80
        const val TAG_LENGTH = 16
        private val MAGIC = byteArrayOf(0x4C, 0x42, 0x58, 0x31) // "LBX1"
    }

    private val key = SecretKeySpec(fileKey.copyOf(), "AES")
    private val cipher: Cipher = Cipher.getInstance("AES/GCM/NoPadding")

    private var raf: RandomAccessFile? = null
    private var uri: Uri? = null
    private var opened = false

    private var header16 = ByteArray(16)
    private var plainLength = 0L
    private var chunkSize = 0
    private var chunkCount = 0L

    private var position = 0L
    private var bytesRemaining = 0L

    private var cachedIndex = -1L
    private var cached = ByteArray(0)
    private var cachedLength = 0

    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        transferInitializing(dataSpec)
        try {
            val f = RandomAccessFile(file, "r")
            raf = f
            val header = ByteArray(HEADER_LENGTH)
            f.readFully(header)
            for (i in 0 until 4) {
                if (header[i] != MAGIC[i]) throw IOException("Not a Lockbox file")
            }
            if (header[4].toInt() != 1) throw IOException("Unsupported version")
            val shift = header[5].toInt()
            if (shift < 12 || shift > 24) throw IOException("Bad chunk size")
            chunkSize = 1 shl shift
            header16 = header.copyOfRange(0, 16)
            plainLength = ByteBuffer.wrap(header, 8, 8).order(ByteOrder.LITTLE_ENDIAN).long
            chunkCount = if (plainLength == 0L) 1 else (plainLength + chunkSize - 1) / chunkSize
            if (cached.size < chunkSize) cached = ByteArray(chunkSize + TAG_LENGTH)
        } catch (e: IOException) {
            throw DataSourceException(e, PlaybackException.ERROR_CODE_IO_UNSPECIFIED)
        }
        if (dataSpec.position > plainLength) {
            throw DataSourceException(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
        }
        position = dataSpec.position
        bytesRemaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) {
            min(dataSpec.length, plainLength - position)
        } else {
            plainLength - position
        }
        opened = true
        transferStarted(dataSpec)
        return bytesRemaining
    }

    private fun loadChunk(index: Long) {
        if (index == cachedIndex) return
        val f = raf ?: throw IOException("Closed")
        val last = index == chunkCount - 1
        val plainLen = if (last) (plainLength - index * chunkSize).toInt() else chunkSize
        val offset = HEADER_LENGTH.toLong() + index * (chunkSize + TAG_LENGTH)
        val ct = ByteArray(plainLen + TAG_LENGTH)
        f.seek(offset)
        f.readFully(ct)

        val nonce = ByteArray(12)
        ByteBuffer.wrap(nonce, 4, 8).order(ByteOrder.BIG_ENDIAN).putLong(index)
        val aad = ByteArray(25)
        System.arraycopy(header16, 0, aad, 0, 16)
        ByteBuffer.wrap(aad, 16, 8).order(ByteOrder.BIG_ENDIAN).putLong(index)
        aad[24] = if (last) 1 else 0

        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        val n = try {
            cipher.doFinal(ct, 0, ct.size, cached, 0)
        } catch (e: Exception) {
            throw IOException("Integrity check failed", e)
        }
        cachedLength = n
        cachedIndex = index
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT
        val index = position / chunkSize
        try {
            loadChunk(index)
        } catch (e: IOException) {
            throw DataSourceException(e, PlaybackException.ERROR_CODE_IO_UNSPECIFIED)
        }
        val within = (position - index * chunkSize).toInt()
        val n = min(min(length.toLong(), (cachedLength - within).toLong()), bytesRemaining).toInt()
        System.arraycopy(cached, within, buffer, offset, n)
        position += n
        bytesRemaining -= n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = uri

    /** Decrypted size. Valid after [open]. */
    val plaintextSize: Long get() = plainLength

    /** Random-access read (for frame grabs). Call [open] first. -1 = end. */
    fun readAt(pos: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (pos >= plainLength) return -1
        if (size == 0) return 0
        val index = pos / chunkSize
        loadChunk(index)
        val within = (pos - index * chunkSize).toInt()
        val n = min(size, cachedLength - within)
        System.arraycopy(cached, within, buffer, offset, n)
        return n
    }

    override fun close() {
        uri = null
        try {
            raf?.close()
        } catch (_: IOException) {
        } finally {
            raf = null
            cachedIndex = -1
            if (opened) {
                opened = false
                transferEnded()
            }
        }
    }
}

/** Lets MediaMetadataRetriever read an encrypted Lockbox file directly. */
@OptIn(UnstableApi::class)
class EncryptedMediaDataSource(file: File, key: ByteArray) : android.media.MediaDataSource() {
    private val source = EncryptedBlobDataSource(file, key).also {
        it.open(DataSpec(Uri.fromFile(file)))
    }

    @Synchronized
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int =
        source.readAt(position, buffer, offset, size)

    override fun getSize(): Long = source.plaintextSize

    @Synchronized
    override fun close() = source.close()
}
