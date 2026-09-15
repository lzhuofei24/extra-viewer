package com.bestviewer.best_viewer

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.database.Cursor
import java.nio.ByteBuffer
import android.os.Bundle
import android.os.SystemClock
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
    companion object {
        val DIRECTORY_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
    }

    private val directoryRequestCode = 7201
    private var pendingDirectoryResult: MethodChannel.Result? = null
    // SAF providers are IPC-bound. A small pool overlaps reads without
    // allowing a large directory scan to flood the provider or disk cache.
    private val sourceExecutor = Executors.newFixedThreadPool(8)
    private val scanExecutor = Executors.newSingleThreadExecutor()
    private val thumbnailJobs = ConcurrentHashMap<String, ThumbnailJob>()
    private val sourceJobs = ConcurrentHashMap<String, ThumbnailJob>()
    private val sourceDescriptors = ConcurrentHashMap<String, android.os.ParcelFileDescriptor>()

    private inner class ThumbnailJob(private val reply: MethodChannel.Result) : MethodChannel.Result {
        val cancelled = AtomicBoolean(false)
        private val replied = AtomicBoolean(false)
        var future: Future<*>? = null
        @Volatile var stream: java.io.Closeable? = null
        fun checkActive() {
            if (cancelled.get() || Thread.currentThread().isInterrupted) {
                throw InterruptedException("Thumbnail cancelled")
            }
        }
        @Synchronized fun cancel() {
            cancelled.set(true)
            future?.cancel(true)
            val openStream = stream
            if (openStream != null) {
                Thread({ try { openStream.close() } catch (_: Exception) {} }, "source-cancel").apply { isDaemon = true }.start()
            }
            error("cancelled", "Thumbnail cancelled", null)
        }
        @Synchronized fun publishFile(path: String) {
            if (cancelled.get()) File(path).delete() else success(path)
        }
        override fun success(value: Any?) {
            if (replied.compareAndSet(false, true)) runOnUiThread { reply.success(value) }
        }
        override fun error(code: String, message: String?, details: Any?) {
            if (replied.compareAndSet(false, true)) runOnUiThread { reply.error(code, message, details) }
        }
        override fun notImplemented() {
            if (replied.compareAndSet(false, true)) runOnUiThread { reply.notImplemented() }
        }
    }
    private var scanProgressSink: EventChannel.EventSink? = null
    private var directoryScanSession: DirectoryScanSession? = null
    private val directoryReaders = ConcurrentHashMap<String, SafDirectoryReader>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Session files are only valid while this app process is alive.
        clearCacheDirectory("saf_session")
        clearCacheDirectory("saf_scan_transient")
        clearCacheDirectory("saf_transient")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "best_viewer/directory_picker",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openSourceDescriptor" -> sourceExecutor.execute {
                    try {
                        val descriptor = contentResolver.openFileDescriptor(
                            Uri.parse(call.argument<String>("source")!!), "r"
                        ) ?: throw IllegalArgumentException("Source cannot be opened")
                        val token = java.util.UUID.randomUUID().toString()
                        runOnUiThread {
                            if (isDestroyed) {
                                descriptor.close()
                                result.error("source_closed", "Activity closed", null)
                            } else {
                                sourceDescriptors[token] = descriptor
                                result.success(mapOf("token" to token, "path" to "/proc/self/fd/${descriptor.fd}"))
                            }
                        }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("source_open", error.message, null) }
                    }
                }
                "closeSourceDescriptor" -> {
                    try {
                        sourceDescriptors.remove(call.argument<String>("token"))?.close()
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("source_close", error.message, null)
                    }
                }
                "pickDirectory" -> openDirectoryPicker(result)
                "resolveSourceDirectory", "openSourceDirectory", "readSourceDirectory", "closeSourceDirectory" -> {
                    scanExecutor.execute {
                        try {
                            val value: Any? = when (call.method) {
                                "resolveSourceDirectory" -> {
                                    val uri = Uri.parse(call.argument<String>("source")!!)
                                    val id = resolveDirectoryId(uri, call.argument<String>("relativeScope") ?: "")
                                    DocumentsContract.buildDocumentUriUsingTree(uri, id).toString()
                                }
                                "openSourceDirectory" -> {
                                    val reader = SafDirectoryReader(contentResolver, Uri.parse(call.argument<String>("source")!!))
                                    val token = java.util.UUID.randomUUID().toString()
                                    directoryReaders[token] = reader
                                    token
                                }
                                "readSourceDirectory" -> directoryReaders[call.argument<String>("token")]
                                    ?.readPage() ?: throw IllegalStateException("Directory session closed")
                                else -> { directoryReaders.remove(call.argument<String>("token"))?.close(); null }
                            }
                            runOnUiThread { result.success(value) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("source_unavailable", "Directory enumeration incomplete", error.message) }
                        }
                    }
                }
                "listDirectoryTree" -> listDirectory(call.argument<String>("source"), result)
                "startDirectoryTreeScan" -> startDirectoryTreeScan(
                    call.argument<String>("source"),
                    call.argument<String>("relativeScope"),
                    result,
                )
                "nextDirectoryTreeBatch" -> nextDirectoryTreeBatch(result)
                "cancelDirectoryTreeScan" -> cancelDirectoryTreeScan(result)
                "materializeDocument" -> materialize(
                    call.argument<String>("source"),
                    call.argument<String>("name"),
                    call.argument<String>("cacheScope"),
                    call.argument<Number>("maxBytes")?.toLong(),
                    call.argument<String>("requestId"),
                    result,
                )
                "cancelMaterialization" -> {
                    call.argument<String>("requestId")?.let { sourceJobs.remove(it)?.cancel() }
                    result.success(null)
                }
                "readDocumentPrefix" -> readDocumentPrefix(
                    call.argument<String>("source"),
                    call.argument<Int>("maxBytes") ?: 64 * 1024,
                    result,
                )
                "createImageThumbnail" -> createImageThumbnail(
                    call.argument<String>("source"),
                    call.argument<String>("outputPath"),
                    call.argument<String>("requestId"),
                    call.argument<Int>("targetPixelCount") ?: 360000,
                    call.argument<Int>("quality") ?: 80,
                    result,
                )
                "createVideoThumbnail" -> createVideoThumbnail(
                    call.argument<String>("source"),
                    call.argument<String>("outputPath"),
                    call.argument<String>("requestId"),
                    call.argument<Int>("targetPixelCount") ?: 360000,
                    call.argument<Int>("quality") ?: 80,
                    result,
                )
                "encodeNodePreview" -> encodeNodePreview(
                    call.argument<ByteArray>("pixels"),
                    call.argument<Int>("width"),
                    call.argument<Int>("height"),
                    call.argument<String>("outputPath"),
                    call.argument<Int>("quality") ?: 80,
                    result,
                )
                "cancelThumbnail" -> cancelThumbnail(
                    call.argument<String>("requestId"),
                    result,
                )
                "clearTransientDocuments" -> clearTransientDocuments(result)
                "clearSessionDocuments" -> clearSessionDocuments(result)
                else -> result.notImplemented()
            }
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "best_viewer/directory_picker_progress",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                scanProgressSink = events
            }

            override fun onCancel(arguments: Any?) {
                scanProgressSink = null
            }
        })
    }

    private fun openDirectoryPicker(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null) {
            result.error("busy", "A directory picker is already open.", null)
            return
        }
        pendingDirectoryResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        startActivityForResult(intent, directoryRequestCode)
    }

    private fun listDirectory(source: String?, result: MethodChannel.Result) {
        if (source.isNullOrBlank()) {
            result.error("argument", "source is required", null)
            return
        }
        sourceExecutor.execute {
            try {
                val files = listDirectoryTree(Uri.parse(source))
                runOnUiThread { result.success(files) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("list", "Cannot list selected directory.", error.message)
                }
            }
        }
    }

    private fun startDirectoryTreeScan(source: String?, relativeScope: String?, result: MethodChannel.Result) {
        if (source.isNullOrBlank()) {
            result.error("argument", "source is required", null)
            return
        }
        scanExecutor.execute {
            try {
                val uri = Uri.parse(source)
                val scope = relativeScope?.trim('/') ?: ""
                val existing = directoryScanSession
                if (existing != null && existing.source == uri.toString() && existing.scope == scope) {
                    runOnUiThread { result.success(mapOf("total" to existing.total)) }
                    return@execute
                }
                existing?.close()
                val startDocumentId = resolveDirectoryId(uri, scope)
                // Count without retaining document metadata. The following
                // pull session is independent, so Dart can show a stable
                // total while it persists the durable manifest in batches.
                val total = 0
                directoryScanSession = DirectoryScanSession(uri, total, startDocumentId, scope)
                runOnUiThread { result.success(mapOf("total" to total)) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("list", "Cannot list selected directory.", error.message)
                }
            }
        }
    }

    private fun nextDirectoryTreeBatch(result: MethodChannel.Result) {
        scanExecutor.execute {
            try {
                val session = directoryScanSession
                    ?: throw IllegalStateException("No active directory scan")
                val batch = session.nextBatch(100)
                if (batch.completed) directoryScanSession = null
                runOnUiThread {
                    scanProgressSink?.success(mapOf(
                        "discovered" to batch.discovered,
                        "completed" to batch.completed,
                    ))
                    result.success(mapOf(
                        "documents" to batch.documents,
                        "completed" to batch.completed,
                    ))
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("list", "Cannot read selected directory batch.", error.message)
                }
            }
        }
    }

    private fun cancelDirectoryTreeScan(result: MethodChannel.Result) {
        scanExecutor.execute {
            directoryScanSession?.close()
            directoryScanSession = null
            runOnUiThread { result.success(null) }
        }
    }

    private fun materialize(
        source: String?,
        name: String?,
        cacheScope: String?,
        maxBytes: Long?,
        requestId: String?,
        result: MethodChannel.Result,
    ) {
        if (source.isNullOrBlank()) {
            result.error("argument", "source is required", null)
            return
        }
        val id = requestId ?: java.util.UUID.randomUUID().toString()
        val job = ThumbnailJob(result)
        sourceJobs[id] = job
        job.future = sourceExecutor.submit {
            try {
                job.checkActive()
                val path = materializeDocument(Uri.parse(source), name, cacheScope, maxBytes, job)
                job.publishFile(path)
            } catch (error: Exception) {
                job.error("materialize", "Cannot read selected document.", error.message)
            } finally {
                sourceJobs.remove(id, job)
            }
        }
    }

    private fun createImageThumbnail(
        source: String?,
        outputPath: String?,
        requestId: String?,
        targetPixelCount: Int,
        quality: Int,
        result: MethodChannel.Result,
    ) {
        if (source.isNullOrBlank() || outputPath.isNullOrBlank()) {
            result.error("argument", "source and outputPath are required", null)
            return
        }
        val job = ThumbnailJob(result)
        if (requestId != null) thumbnailJobs[requestId] = job
        job.future = sourceExecutor.submit {
            var ownedBitmap: Bitmap? = null
            try {
                job.checkActive()
                val readStarted = SystemClock.elapsedRealtime()
                var sourceWidth = 0
                var sourceHeight = 0
                var decoded: Bitmap? = null
                val readMs = SystemClock.elapsedRealtime() - readStarted
                val decodeStarted = SystemClock.elapsedRealtime()
                // Do not ask ContentResolver for its thumbnail cache here.
                // Some SAF providers return an old or undersized derivative,
                // which then becomes a permanently blurry app thumbnail. Read
                // the original stream with BitmapFactory and downsample it once
                // to our own v6 WebP specification instead.
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                decodeBitmap(source, bounds)
                sourceWidth = bounds.outWidth
                sourceHeight = bounds.outHeight
                if (sourceWidth <= 0 || sourceHeight <= 0) {
                    throw IllegalArgumentException("Unsupported image source")
                }
                val (requestedWidth, requestedHeight) = thumbnailDimensions(
                    sourceWidth,
                    sourceHeight,
                    targetPixelCount,
                )
                val options = BitmapFactory.Options().apply {
                    inSampleSize = sampleSizeFor(sourceWidth, sourceHeight, requestedWidth, requestedHeight)
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                }
                decoded = decodeBitmap(source, options)
                    ?: throw IllegalArgumentException("Image decode returned no bitmap")
                ownedBitmap = decoded
                job.checkActive()
                val decodeMs = SystemClock.elapsedRealtime() - decodeStarted
                val (targetWidth, targetHeight) = thumbnailDimensions(
                    decoded.width,
                    decoded.height,
                    targetPixelCount,
                )
                val resizeStarted = SystemClock.elapsedRealtime()
                val scaled = if (decoded.width == targetWidth && decoded.height == targetHeight) {
                    decoded
                } else {
                    Bitmap.createScaledBitmap(decoded, targetWidth, targetHeight, true).also {
                        if (it !== decoded) decoded.recycle()
                    }
                }
                ownedBitmap = scaled
                job.checkActive()
                val resizeMs = SystemClock.elapsedRealtime() - resizeStarted
                val encodeStarted = SystemClock.elapsedRealtime()
                val writeMs = writeWebpAtomically(scaled, quality, outputPath, requestId, job)
                val encodeMs = SystemClock.elapsedRealtime() - encodeStarted - writeMs
                scaled.recycle()
                runOnUiThread {
                    job.success(mapOf(
                        "outputPath" to outputPath,
                        "width" to targetWidth,
                        "height" to targetHeight,
                        "sourcePixelCount" to sourceWidth.toLong() * sourceHeight.toLong(),
                        "readMs" to readMs,
                        "decodeMs" to decodeMs,
                        "resizeMs" to resizeMs,
                        "encodeMs" to encodeMs.coerceAtLeast(0),
                        "writeMs" to writeMs,
                    ))
                }
            } catch (error: Exception) {
                runOnUiThread {
                    job.error("thumbnail", "Cannot create image thumbnail.", error.message)
                }
            } finally {
                ownedBitmap?.let { if (!it.isRecycled) it.recycle() }
                if (requestId != null) thumbnailJobs.remove(requestId, job)
            }
        }
    }

    private fun createVideoThumbnail(
        source: String?,
        outputPath: String?,
        requestId: String?,
        targetPixelCount: Int,
        quality: Int,
        result: MethodChannel.Result,
    ) {
        if (source.isNullOrBlank() || outputPath.isNullOrBlank()) {
            result.error("argument", "source and outputPath are required", null)
            return
        }
        val job = ThumbnailJob(result)
        if (requestId != null) thumbnailJobs[requestId] = job
        job.future = sourceExecutor.submit {
            var ownedBitmap: Bitmap? = null
            val retriever = MediaMetadataRetriever()
            try {
                job.checkActive()
                val readStarted = SystemClock.elapsedRealtime()
                if (source.startsWith("content://")) {
                    retriever.setDataSource(this, Uri.parse(source))
                } else {
                    retriever.setDataSource(source)
                }
                val sourceWidth = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
                )?.toIntOrNull() ?: 0
                val sourceHeight = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
                )?.toIntOrNull() ?: 0
                val (targetWidth, targetHeight) = thumbnailDimensions(
                    sourceWidth.coerceAtLeast(1), sourceHeight.coerceAtLeast(1), targetPixelCount,
                )
                val readMs = SystemClock.elapsedRealtime() - readStarted
                val decodeStarted = SystemClock.elapsedRealtime()
                val durationUs = (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L) * 1000L
                val times = listOf(if (durationUs > 0) minOf(2_000_000L, durationUs / 2) else 2_000_000L, 0L, -1L).distinct()
                var decoded: Bitmap? = null
                for (time in times) {
                    job.checkActive()
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O_MR1 && sourceWidth > 0 && sourceHeight > 0) {
                        decoded = try {
                            retriever.getScaledFrameAtTime(time, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, targetWidth, targetHeight)
                        } catch (_: RuntimeException) { null }
                    }
                    if (decoded != null) break
                }
                // Some vendor decoders reject scaled extraction while ordinary extraction works.
                if (decoded == null) for (time in times) {
                    job.checkActive()
                    decoded = try { retriever.getFrameAtTime(time, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) }
                        catch (_: RuntimeException) { null }
                    if (decoded != null) break
                }
                val frame = decoded ?: throw IllegalArgumentException("Video contains no decodable frame after scaled and compatibility retries")
                ownedBitmap = frame
                job.checkActive()
                val decodeMs = SystemClock.elapsedRealtime() - decodeStarted
                val resizeStarted = SystemClock.elapsedRealtime()
                val (frameWidth, frameHeight) = thumbnailDimensions(frame.width, frame.height, targetPixelCount)
                val scaled = if (frame.width == frameWidth && frame.height == frameHeight) {
                    frame
                } else {
                    Bitmap.createScaledBitmap(frame, frameWidth, frameHeight, true).also {
                        if (it !== frame) frame.recycle()
                    }
                }
                ownedBitmap = scaled
                job.checkActive()
                val resizeMs = SystemClock.elapsedRealtime() - resizeStarted
                val encodeStarted = SystemClock.elapsedRealtime()
                val writeMs = writeWebpAtomically(scaled, quality, outputPath, requestId, job)
                val encodeMs = SystemClock.elapsedRealtime() - encodeStarted - writeMs
                scaled.recycle()
                val durationMs = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION,
                )?.toLongOrNull()
                runOnUiThread {
                    job.success(mapOf(
                        "outputPath" to outputPath,
                        "width" to targetWidth,
                        "height" to targetHeight,
                        "durationMs" to durationMs,
                        "readMs" to readMs,
                        "decodeMs" to decodeMs,
                        "resizeMs" to resizeMs,
                        "encodeMs" to encodeMs.coerceAtLeast(0),
                        "writeMs" to writeMs,
                    ))
                }
            } catch (error: Exception) {
                runOnUiThread {
                    job.error("videoThumbnail", "Cannot create video thumbnail.", error.message)
                }
            } finally {
                ownedBitmap?.let { if (!it.isRecycled) it.recycle() }
                if (requestId != null) {
                    thumbnailJobs.remove(requestId, job)
                }
                retriever.release()
            }
        }
    }

    private fun encodeNodePreview(
        pixels: ByteArray?,
        width: Int?,
        height: Int?,
        outputPath: String?,
        quality: Int,
        result: MethodChannel.Result,
    ) {
        if (pixels == null || width == null || height == null || outputPath.isNullOrBlank()) {
            result.error("argument", "pixels, dimensions and outputPath are required", null)
            return
        }
        val expectedBytes = width.toLong() * height.toLong() * 4L
        if (width <= 0 || height <= 0 || expectedBytes != pixels.size.toLong()) {
            result.error("argument", "Invalid node preview pixel buffer", null)
            return
        }
        sourceExecutor.execute {
            var bitmap: Bitmap? = null
            try {
                bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                // Dart sends RGBA bytes, matching Android's ARGB_8888 buffer
                // layout on the supported devices.
                bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(pixels))
                val writeMs = writeWebpAtomically(
                    bitmap,
                    quality.coerceIn(1, 100),
                    outputPath,
                    null,
                )
                runOnUiThread {
                    result.success(mapOf(
                        "outputPath" to outputPath,
                        "width" to width,
                        "height" to height,
                        "writeMs" to writeMs,
                    ))
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("nodePreview", "Cannot encode node preview.", error.message)
                }
            } finally {
                bitmap?.recycle()
            }
        }
    }

    private fun cancelThumbnail(
        requestId: String?,
        result: MethodChannel.Result,
    ) {
        if (!requestId.isNullOrBlank()) {
            thumbnailJobs.remove(requestId)?.cancel()
        }
        result.success(null)
    }

    private fun writeWebpAtomically(
        bitmap: Bitmap,
        quality: Int,
        outputPath: String,
        requestId: String?,
        job: ThumbnailJob? = null,
    ): Long {
        val started = SystemClock.elapsedRealtime()
        val output = File(outputPath)
        output.parentFile?.mkdirs()
        val temporary = File("${output.absolutePath}.tmp")
        try {
        job?.checkActive()
        temporary.outputStream().use { stream ->
            val compressed = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                bitmap.compress(Bitmap.CompressFormat.WEBP_LOSSY, quality.coerceIn(1, 100), stream)
            } else {
                @Suppress("DEPRECATION")
                bitmap.compress(Bitmap.CompressFormat.WEBP, quality.coerceIn(1, 100), stream)
            }
            if (!compressed) throw IllegalStateException("WebP compression failed")
            stream.fd.sync()
        }
        job?.checkActive()
        if (output.exists()) {
            throw IllegalStateException("Cannot replace immutable thumbnail")
        }
        if (!temporary.renameTo(output)) {
            throw IllegalStateException("Cannot finalize thumbnail output")
        }
        return SystemClock.elapsedRealtime() - started
        } finally {
            temporary.delete()
        }
    }

    private fun thumbnailDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        targetPixelCount: Int,
    ): Pair<Int, Int> {
        val width = sourceWidth.coerceAtLeast(1)
        val height = sourceHeight.coerceAtLeast(1)
        val sourcePixels = width.toLong() * height.toLong()
        val targetPixels = targetPixelCount.coerceAtLeast(1).toLong()
        if (sourcePixels <= targetPixels) return width to height
        val scale = sqrt(targetPixels.toDouble() / sourcePixels.toDouble())
        return (width * scale).roundToInt().coerceAtLeast(1) to
            (height * scale).roundToInt().coerceAtLeast(1)
    }

    private fun decodeBitmap(source: String, options: BitmapFactory.Options): Bitmap? {
        return if (source.startsWith("content://")) {
            contentResolver.openInputStream(Uri.parse(source))?.use { stream ->
                BitmapFactory.decodeStream(stream, null, options)
            }
        } else {
            BitmapFactory.decodeFile(source, options)
        }
    }

    private fun sampleSizeFor(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
    ): Int {
        var sample = 1
        while (sourceWidth / (sample * 2) >= targetWidth &&
            sourceHeight / (sample * 2) >= targetHeight
        ) sample *= 2
        return sample
    }

    private fun clearTransientDocuments(result: MethodChannel.Result) {
        sourceExecutor.execute {
            try {
                clearCacheDirectory("saf_scan_transient")
                // Clean up the retired pre-upgrade directory once as well.
                clearCacheDirectory("saf_transient")
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("cleanup", "Cannot clear transient source files.", error.message)
                }
            }
        }
    }

    private fun clearSessionDocuments(result: MethodChannel.Result) {
        sourceExecutor.execute {
            try {
                clearCacheDirectory("saf_session")
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("cleanup", "Cannot clear session source files.", error.message)
                }
            }
        }
    }

    private fun clearCacheDirectory(name: String) {
        val directory = File(cacheDir, name)
        directory.listFiles()?.forEach { file ->
            if (file.isDirectory) file.deleteRecursively() else file.delete()
        }
        directory.delete()
    }

    override fun onDestroy() {
        sourceDescriptors.values.forEach { try { it.close() } catch (_: Exception) {} }
        sourceDescriptors.clear()
        directoryReaders.values.forEach { it.close() }
        directoryReaders.clear()
        sourceExecutor.shutdownNow()
        scanExecutor.shutdownNow()
        directoryScanSession?.close()
        super.onDestroy()
    }

    @Deprecated("Deprecated in Android SDK")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != directoryRequestCode) return
        val result = pendingDirectoryResult ?: return
        pendingDirectoryResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        val permissions = (data?.flags ?: 0) and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        try {
            contentResolver.takePersistableUriPermission(uri, permissions)
        } catch (error: SecurityException) {
            result.error("permission", "Cannot persist directory permission.", error.message)
            return
        }
        result.success(mapOf("uri" to uri.toString(), "displayName" to displayNameFor(uri)))
    }

    private fun displayNameFor(uri: Uri): String {
        val treeId = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (_: Exception) {
            null
        }
        return treeId
            ?.substringAfterLast(':')
            ?.substringAfterLast('/')
            ?.takeIf { it.isNotBlank() }
            ?: uri.lastPathSegment
            ?: "已选目录"
    }

    private fun listDirectoryTree(rootUri: Uri): List<Map<String, Any?>> {
        val results = mutableListOf<Map<String, Any?>>()
        var discovered = 0
        val pending = ArrayDeque<Pair<String, String>>()
        pending.add(DocumentsContract.getTreeDocumentId(rootUri) to "")
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )

        while (pending.isNotEmpty()) {
            val (parentDocumentId, relativeDirectory) = pending.removeFirst()
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, parentDocumentId)
            contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
                val modifiedColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                while (cursor.moveToNext()) {
                    val documentId = cursor.getString(idColumn) ?: continue
                    val name = cursor.getString(nameColumn)?.takeIf { it.isNotBlank() } ?: continue
                    val mimeType = cursor.getString(mimeColumn)
                    val relativePath = if (relativeDirectory.isEmpty()) name else "$relativeDirectory/$name"
                    if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                        pending.add(documentId to relativePath)
                        continue
                    }
                    discovered++
                    if (discovered == 1 || discovered % 25 == 0) {
                        runOnUiThread {
                            scanProgressSink?.success(mapOf("discovered" to discovered))
                        }
                    }
                    results += mapOf(
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId).toString(),
                        "relativePath" to relativePath,
                        "name" to name,
                        "mimeType" to mimeType,
                        "size" to if (cursor.isNull(sizeColumn)) 0L else cursor.getLong(sizeColumn),
                        "modifiedAtMs" to if (cursor.isNull(modifiedColumn)) 0L else cursor.getLong(modifiedColumn),
                    )
                }
            }
        }
        runOnUiThread {
            scanProgressSink?.success(mapOf("discovered" to discovered, "completed" to true))
        }
        return results
    }

    private fun resolveDirectoryId(rootUri: Uri, scope: String): String {
        var currentId = DocumentsContract.getTreeDocumentId(rootUri)
        if (scope.isEmpty()) return currentId
        for (segment in scope.split('/').filter { it.isNotEmpty() }) {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, currentId)
            var nextId: String? = null
            contentResolver.query(childrenUri, DIRECTORY_PROJECTION, null, null, null)?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                while (cursor.moveToNext()) {
                    if (cursor.getString(nameColumn) == segment &&
                        cursor.getString(mimeColumn) == DocumentsContract.Document.MIME_TYPE_DIR) {
                        nextId = cursor.getString(idColumn)
                        break
                    }
                }
            }
            currentId = nextId ?: throw IllegalArgumentException("Directory no longer exists: $scope")
        }
        return currentId
    }

    private fun countDirectoryTree(rootUri: Uri, startDocumentId: String, scope: String): Int {
        val session = DirectoryScanSession(rootUri, 0, startDocumentId, scope)
        var discovered = 0
        try {
            while (true) {
                val batch = session.nextBatch(500)
                discovered = batch.discovered
                if (batch.completed) break
            }
        } finally {
            session.close()
        }
        return discovered
    }

    private inner class DirectoryScanSession(
        private val rootUri: Uri,
        val total: Int,
        startDocumentId: String,
        val scope: String,
    ) {
        val source: String = rootUri.toString()
        private val pending = ArrayDeque<Pair<String, String>>()
        private var cursor: Cursor? = null
        private var relativeDirectory = ""
        var discovered = 0
            private set

        init {
            pending.add(startDocumentId to "")
        }

        fun nextBatch(limit: Int): DirectoryScanBatch {
            val documents = mutableListOf<Map<String, Any?>>()
            while (documents.size < limit) {
                if (cursor == null && !openNextDirectory()) break
                val activeCursor = cursor ?: break
                if (!activeCursor.moveToNext()) {
                    activeCursor.close()
                    cursor = null
                    continue
                }
                val idColumn = activeCursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                )
                val nameColumn = activeCursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                )
                val mimeColumn = activeCursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                )
                val sizeColumn = activeCursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_SIZE,
                )
                val modifiedColumn = activeCursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                )
                val documentId = activeCursor.getString(idColumn) ?: continue
                val name = activeCursor.getString(nameColumn)?.takeIf { it.isNotBlank() } ?: continue
                val mimeType = activeCursor.getString(mimeColumn)
                val relativePath = if (relativeDirectory.isEmpty()) name else "$relativeDirectory/$name"
                if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                    pending.add(documentId to relativePath)
                    continue
                }
                discovered++
                documents += mapOf(
                    "uri" to DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId).toString(),
                    "relativePath" to relativePath,
                    "name" to name,
                    "mimeType" to mimeType,
                    "size" to if (activeCursor.isNull(sizeColumn)) 0L else activeCursor.getLong(sizeColumn),
                    "modifiedAtMs" to if (activeCursor.isNull(modifiedColumn)) 0L else activeCursor.getLong(modifiedColumn),
                )
            }
            return DirectoryScanBatch(
                documents = documents,
                completed = cursor == null && pending.isEmpty(),
                discovered = discovered,
            )
        }

        fun close() {
            cursor?.close()
            cursor = null
            pending.clear()
        }

        private fun openNextDirectory(): Boolean {
            while (pending.isNotEmpty()) {
                val (documentId, path) = pending.removeFirst()
                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, documentId)
                val nextCursor = contentResolver.query(
                    childrenUri,
                    DIRECTORY_PROJECTION,
                    null,
                    null,
                    null,
                ) ?: throw IllegalStateException("Directory provider unavailable: $path")
                cursor = nextCursor
                relativeDirectory = path
                return true
            }
            return false
        }
    }

    private data class DirectoryScanBatch(
        val documents: List<Map<String, Any?>>,
        val completed: Boolean,
        val discovered: Int,
    )


    private fun materializeDocument(uri: Uri, name: String?, cacheScope: String?, maxBytes: Long?, job: ThumbnailJob): String {
        val extension = name?.substringAfterLast('.', "")?.takeIf { it.isNotEmpty() }
        val directoryName = when (cacheScope) {
            "scan" -> "saf_scan_transient"
            "session", null -> "saf_session"
            else -> throw IllegalArgumentException("Invalid materialization cache scope")
        }
        val outputDirectory = File(cacheDir, directoryName).apply { mkdirs() }
        val output = File.createTempFile("source_", extension?.let { ".${it}" }, outputDirectory)
        try {
          contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Cannot open selected document" }
            job.stream = input
            job.checkActive()
            output.outputStream().use { outputStream ->
                val buffer = ByteArray(64 * 1024)
                var copied = 0L
                while (true) {
                    job.checkActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    copied += count
                    require(maxBytes == null || copied <= maxBytes) { "Source exceeds temporary storage budget" }
                    outputStream.write(buffer, 0, count)
                }
            }
          }
          return output.absolutePath
        } catch (error: Exception) {
            output.delete()
            throw error
        } finally {
            job.stream = null
        }
    }

    private fun readDocumentPrefix(
        source: String?,
        requestedBytes: Int,
        result: MethodChannel.Result,
    ) {
        if (source.isNullOrBlank()) {
            result.error("argument", "source is required", null)
            return
        }
        val maxBytes = requestedBytes.coerceIn(0, 64 * 1024)
        sourceExecutor.execute {
            try {
                val buffer = ByteArray(maxBytes)
                var offset = 0
                contentResolver.openInputStream(Uri.parse(source)).use { input ->
                    requireNotNull(input) { "Cannot open selected document" }
                    while (offset < buffer.size) {
                        val count = input.read(buffer, offset, buffer.size - offset)
                        if (count <= 0) break
                        offset += count
                    }
                }
                val prefix = if (offset == buffer.size) buffer else buffer.copyOf(offset)
                runOnUiThread { result.success(prefix) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("fingerprint", "Cannot read document prefix.", error.message)
                }
            }
        }
    }
}
