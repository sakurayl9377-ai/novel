package com.novel.novel_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Disk-backed, bounded region decoding for very tall manga images.
 *
 * The channel intentionally returns file paths instead of bitmap bytes. This
 * avoids copying large encoded images through the Flutter platform channel and
 * lets Flutter's image cache own only the few decoded tiles near the viewport.
 */
class MangaTileChannel(
    context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL_NAME = "com.novel.novel_app/manga_tiles"

        private const val CACHE_VERSION = "v1"
        private const val DEFAULT_CACHE_BYTES = 384L * 1024L * 1024L
        private const val MIN_CACHE_BYTES = 64L * 1024L * 1024L
        private const val MAX_CACHE_BYTES = 1024L * 1024L * 1024L
        private const val DEFAULT_MAX_AGE_MS = 14L * 24L * 60L * 60L * 1000L
        private const val MIN_MAX_AGE_MS = 24L * 60L * 60L * 1000L
        private const val MAX_MAX_AGE_MS = 90L * 24L * 60L * 60L * 1000L
        private const val MAX_SOURCE_BYTES = 256L * 1024L * 1024L
        private const val MAX_SOURCE_DIMENSION = 250_000
        private const val MAX_SOURCE_RECT_DIMENSION = 32_768
        private const val MIN_TARGET_WIDTH = 64
        private const val MAX_TARGET_WIDTH = 2_048
        private const val MAX_DECODE_WIDTH = 2_560
        private const val MAX_DECODE_HEIGHT = 4_096
        private const val MAX_DECODE_PIXELS = 6_000_000L
        private const val MAX_SAMPLE_SIZE = 64
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 30_000
        private const val MAX_REDIRECTS = 5
        private const val MAX_PREPARED_SOURCES = 64

        private val SOURCE_ID_PATTERN = Regex("^[a-f0-9]{64}$")
    }

    private val appContext = context.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val disposed = AtomicBoolean(false)
    private val executor = Executors.newFixedThreadPool(2, TileThreadFactory())
    private val registryLock = Any()
    private val sources = ConcurrentHashMap<String, PreparedSource>()
    private val activeWrites = ConcurrentHashMap.newKeySet<String>()
    private val lastAutomaticPruneMs = AtomicLong(0L)
    private val cacheRoot = File(appContext.cacheDir, "manga_region_tiles/$CACHE_VERSION")
    private val sourceCache = File(cacheRoot, "sources")
    private val tileCache = File(cacheRoot, "tiles")
    private val allowedLocalRoots = buildList {
        add(appContext.filesDir)
        add(appContext.cacheDir)
        add(appContext.noBackupFilesDir)
        appContext.externalCacheDirs.filterNotNull().forEach(::add)
        appContext.getExternalFilesDirs(null).filterNotNull().forEach(::add)
    }.mapNotNull { root -> runCatching { root.canonicalFile }.getOrNull() }
        .distinctBy { it.path }

    init {
        ensureDirectory(sourceCache)
        ensureDirectory(tileCache)
        channel.setMethodCallHandler(::handleCall)
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        channel.setMethodCallHandler(null)
        val preparedSources = synchronized(registryLock) {
            val snapshot = sources.values.toList()
            sources.clear()
            snapshot
        }
        // Let a currently running decode finish before recycling its native
        // decoder. Queued calls observe [disposed] and return immediately.
        executor.execute {
            preparedSources.forEach { source ->
                synchronized(source.lock) {
                    source.released = true
                    closeDecoder(source)
                }
            }
            activeWrites.clear()
        }
        executor.shutdown()
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(true)
            "prepareSource" -> submit(result) { prepareSource(call) }
            "decodeTile" -> submit(result) { decodeTile(call) }
            "releaseSource" -> submit(result) {
                releaseSource(requireString(call, "sourceId"))
                true
            }
            "pruneCache" -> submit(result) {
                val maxBytes = numberArgument(call, "maxBytes")?.toLong()
                    ?.coerceIn(MIN_CACHE_BYTES, MAX_CACHE_BYTES)
                    ?: DEFAULT_CACHE_BYTES
                val maxAgeMs = numberArgument(call, "maxAgeMs")?.toLong()
                    ?.coerceIn(MIN_MAX_AGE_MS, MAX_MAX_AGE_MS)
                    ?: DEFAULT_MAX_AGE_MS
                pruneCache(maxBytes, maxAgeMs)
            }
            else -> result.notImplemented()
        }
    }

    private fun submit(result: MethodChannel.Result, block: () -> Any?) {
        if (disposed.get()) {
            result.error("DETACHED", "Manga tile channel is detached", null)
            return
        }
        try {
            executor.execute {
                if (disposed.get()) return@execute
                try {
                    val value = block()
                    postResult { result.success(value) }
                } catch (error: TileException) {
                    postResult { result.error(error.code, error.message, null) }
                } catch (error: InterruptedException) {
                    Thread.currentThread().interrupt()
                    postResult { result.error("CANCELLED", "Tile request was cancelled", null) }
                } catch (error: Throwable) {
                    postResult {
                        result.error(
                            "TILE_ERROR",
                            error.message ?: error.javaClass.simpleName,
                            null,
                        )
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("DETACHED", "Manga tile channel is detached", null)
        }
    }

    private fun postResult(callback: () -> Unit) {
        mainHandler.post {
            if (!disposed.get()) callback()
        }
    }

    private fun prepareSource(call: MethodCall): Map<String, Any?> {
        val source = requireString(call, "source")
        if (source.length > 8_192) {
            throw TileException("INVALID_SOURCE", "Image source is too long")
        }
        val referer = call.argument<String>("referer")?.trim()?.takeIf { it.isNotEmpty() }
        if (referer != null) validateHttpUri(referer, "INVALID_REFERER")
        val callerCacheKey = call.argument<String>("cacheKey")?.trim().orEmpty()
        if (callerCacheKey.length > 1_024) {
            throw TileException("INVALID_CACHE_KEY", "Cache key is too long")
        }

        val resolved = resolveSource(source, referer, callerCacheKey)
        val metadata = inspectSource(resolved.file)
        val prepared = synchronized(registryLock) {
            ensureAttached()
            val current = sources[resolved.sourceId]
            if (current != null && current.file.canonicalPath == resolved.file.canonicalPath) {
                current.clientCount += 1
                current.touch()
                current
            } else {
                if (sources.size >= MAX_PREPARED_SOURCES) {
                    throw TileException(
                        "TOO_MANY_SOURCES",
                        "Too many manga image sources are prepared",
                    )
                }
                current?.let { replaced ->
                    synchronized(replaced.lock) {
                        replaced.released = true
                        closeDecoder(replaced)
                    }
                }
                PreparedSource(
                    sourceId = resolved.sourceId,
                    file = resolved.file,
                    width = metadata.width,
                    height = metadata.height,
                    mimeType = metadata.mimeType,
                    byteLength = resolved.file.length(),
                    localInput = resolved.localInput,
                ).also { sources[resolved.sourceId] = it }
            }
        }
        prepared.touch()

        scheduleAutomaticPrune()
        return prepared.toMap()
    }

    private fun scheduleAutomaticPrune() {
        val now = System.currentTimeMillis()
        val previous = lastAutomaticPruneMs.get()
        if (now - previous < 6L * 60L * 60L * 1000L ||
            !lastAutomaticPruneMs.compareAndSet(previous, now)
        ) {
            return
        }
        executor.execute {
            if (disposed.get()) return@execute
            try {
                pruneCache(DEFAULT_CACHE_BYTES, DEFAULT_MAX_AGE_MS)
            } catch (_: Throwable) {
                // A cache maintenance failure must not prevent reading.
            }
        }
    }

    private fun resolveSource(
        source: String,
        referer: String?,
        callerCacheKey: String,
    ): ResolvedSource {
        val trimmed = source.trim()
        if (trimmed.isEmpty()) throw TileException("INVALID_SOURCE", "Image source is empty")
        val uri = runCatching { URI(trimmed) }.getOrNull()
        val scheme = uri?.scheme?.lowercase()
        return when (scheme) {
            "http", "https" -> resolveRemoteSource(trimmed, referer, callerCacheKey)
            "file" -> resolveFileUri(trimmed, callerCacheKey)
            null -> resolveLocalSource(File(trimmed), callerCacheKey)
            else -> throw TileException("UNSUPPORTED_SOURCE", "Only HTTP(S) and local files are supported")
        }
    }

    private fun resolveFileUri(source: String, callerCacheKey: String): ResolvedSource {
        val uri = Uri.parse(source)
        if (!uri.authority.isNullOrEmpty()) {
            throw TileException("INVALID_SOURCE", "Local file URI authority is not allowed")
        }
        return resolveLocalSource(File(uri.path.orEmpty()), callerCacheKey)
    }

    private fun resolveLocalSource(file: File, callerCacheKey: String): ResolvedSource {
        if (!file.isAbsolute) {
            throw TileException("INVALID_SOURCE", "Local image path must be absolute")
        }
        val canonical = try {
            file.canonicalFile
        } catch (_: Exception) {
            throw TileException("INVALID_SOURCE", "Local image path is invalid")
        }
        if (!canonical.isFile || !canonical.canRead()) {
            throw TileException("SOURCE_NOT_FOUND", "Local image is unavailable")
        }
        if (allowedLocalRoots.none { root -> isWithinDirectory(root, canonical) }) {
            throw TileException(
                "SOURCE_OUTSIDE_APP_STORAGE",
                "Local image must be inside app-owned storage",
            )
        }
        validateSourceLength(canonical.length())
        val identity = buildString {
            append("file\u0000")
            append(canonical.path)
            append('\u0000')
            append(canonical.length())
            append('\u0000')
            append(canonical.lastModified())
            append('\u0000')
            append(callerCacheKey)
        }
        return ResolvedSource(
            sourceId = sha256(identity),
            file = canonical,
            localInput = true,
        )
    }

    private fun resolveRemoteSource(
        source: String,
        referer: String?,
        callerCacheKey: String,
    ): ResolvedSource {
        validateHttpUri(source, "INVALID_SOURCE")
        val sourceId = sha256("http\u0000$source\u0000${referer.orEmpty()}\u0000$callerCacheKey")
        val target = safeChild(sourceCache, "$sourceId.source")
        if (target.isFile && target.length() > 0L) {
            try {
                validateSourceLength(target.length())
                inspectSource(target)
                target.setLastModified(System.currentTimeMillis())
                return ResolvedSource(sourceId, target, localInput = false)
            } catch (_: Throwable) {
                target.delete()
            }
        }

        downloadRemote(source, referer, target)
        return ResolvedSource(sourceId, target, localInput = false)
    }

    private fun downloadRemote(source: String, referer: String?, target: File) {
        ensureDirectory(target.parentFile ?: sourceCache)
        val part = safeChild(sourceCache, ".${target.name}.${UUID.randomUUID()}.part")
        val partPath = part.canonicalPath
        activeWrites.add(partPath)
        var current = URL(source)
        var connection: HttpURLConnection? = null
        try {
            var redirects = 0
            while (true) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                validateHttpUri(current.toString(), "INVALID_SOURCE")
                connection = (current.openConnection() as HttpURLConnection).apply {
                    instanceFollowRedirects = false
                    connectTimeout = CONNECT_TIMEOUT_MS
                    readTimeout = READ_TIMEOUT_MS
                    useCaches = true
                    setRequestProperty("User-Agent", "Sakura-Android-MangaTile/1.0")
                    setRequestProperty("Accept", "image/avif,image/webp,image/*,*/*;q=0.8")
                    if (referer != null) setRequestProperty("Referer", referer)
                }
                val status = connection.responseCode
                if (status in 300..399) {
                    if (redirects++ >= MAX_REDIRECTS) {
                        throw TileException("DOWNLOAD_FAILED", "Too many image redirects")
                    }
                    val location = connection.getHeaderField("Location")
                        ?: throw TileException("DOWNLOAD_FAILED", "Image redirect has no location")
                    val next = URL(current, location)
                    connection.disconnect()
                    connection = null
                    current = next
                    continue
                }
                if (status !in 200..299) {
                    throw TileException("DOWNLOAD_FAILED", "Image server returned HTTP $status")
                }
                val announcedLength = connection.contentLengthLong
                if (announcedLength > MAX_SOURCE_BYTES) {
                    throw TileException("SOURCE_TOO_LARGE", "Image source exceeds the disk safety limit")
                }
                var written = 0L
                connection.inputStream.use { input ->
                    FileOutputStream(part).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (Thread.currentThread().isInterrupted) throw InterruptedException()
                            val count = input.read(buffer)
                            if (count < 0) break
                            written += count
                            validateSourceLength(written)
                            output.write(buffer, 0, count)
                        }
                        output.fd.sync()
                    }
                }
                if (written == 0L) throw TileException("DOWNLOAD_FAILED", "Image response is empty")
                inspectSource(part)
                replaceAtomically(part, target)
                target.setLastModified(System.currentTimeMillis())
                return
            }
        } finally {
            connection?.disconnect()
            if (part.exists()) part.delete()
            activeWrites.remove(partPath)
        }
    }

    private fun inspectSource(file: File): SourceMetadata {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) {
            throw TileException("UNSUPPORTED_IMAGE", "Android cannot inspect this image format")
        }
        if (options.outWidth > MAX_SOURCE_DIMENSION || options.outHeight > MAX_SOURCE_DIMENSION) {
            throw TileException("SOURCE_TOO_LARGE", "Image dimensions exceed the safety limit")
        }
        return SourceMetadata(
            width = options.outWidth,
            height = options.outHeight,
            mimeType = options.outMimeType ?: "application/octet-stream",
        )
    }

    private fun decodeTile(call: MethodCall): Map<String, Any?> {
        val sourceId = requireSourceId(call)
        val prepared = sources[sourceId]
            ?: throw TileException("SOURCE_NOT_PREPARED", "Prepare the image source before decoding tiles")
        val x = requireInt(call, "x", minimum = 0)
        val y = requireInt(call, "y", minimum = 0)
        val width = requireInt(call, "width", minimum = 1)
        val height = requireInt(call, "height", minimum = 1)
        val targetWidth = (numberArgument(call, "targetWidth")?.toInt() ?: MAX_TARGET_WIDTH)
            .coerceIn(MIN_TARGET_WIDTH, MAX_TARGET_WIDTH)
        val quality = (numberArgument(call, "quality")?.toInt() ?: 92).coerceIn(70, 100)

        if (width > MAX_SOURCE_RECT_DIMENSION || height > MAX_SOURCE_RECT_DIMENSION) {
            throw TileException("INVALID_RECT", "Requested source tile is too large")
        }
        if (x.toLong() + width > prepared.width || y.toLong() + height > prepared.height) {
            throw TileException("INVALID_RECT", "Requested tile is outside the image")
        }

        val sampleSize = chooseSampleSize(width, height, targetWidth)
        val tileKey = "${x}_${y}_${width}_${height}_${targetWidth}_${quality}_s$sampleSize"
        val sourceTileDirectory = safeChild(tileCache, sourceId)
        ensureDirectory(sourceTileDirectory)
        val target = safeChild(sourceTileDirectory, "$tileKey.webp")

        synchronized(prepared.lock) {
            ensureAttached()
            if (prepared.released) {
                throw TileException("SOURCE_RELEASED", "Image source has been released")
            }
            readCachedTile(target)?.let { cached ->
                prepared.touch()
                target.setLastModified(System.currentTimeMillis())
                return tileResult(
                    sourceId = sourceId,
                    tileKey = tileKey,
                    target = target,
                    width = cached.width,
                    height = cached.height,
                    sampleSize = sampleSize,
                    x = x,
                    y = y,
                    sourceWidth = width,
                    sourceHeight = height,
                )
            }

            val decoder = prepared.decoder?.takeUnless { it.isRecycled }
                ?: try {
                    BitmapRegionDecoder.newInstance(prepared.file.path, false)
                } catch (error: Throwable) {
                    throw TileException(
                        "UNSUPPORTED_IMAGE",
                        error.message ?: "Android cannot region-decode this image",
                    )
                }.also { prepared.decoder = it }
            val region = Rect(x, y, x + width, y + height)
            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            var decoded = try {
                decoder.decodeRegion(region, options)
            } catch (error: OutOfMemoryError) {
                throw TileException("OUT_OF_MEMORY", "Tile is too large for this device")
            } catch (error: Throwable) {
                throw TileException("DECODE_FAILED", error.message ?: "Tile decode failed")
            } ?: throw TileException("DECODE_FAILED", "Android returned an empty tile")

            try {
                val outputScale = min(
                    1.0,
                    min(
                        targetWidth.toDouble() / decoded.width,
                        min(
                            MAX_DECODE_HEIGHT.toDouble() / decoded.height,
                            sqrt(MAX_DECODE_PIXELS.toDouble() / (decoded.width.toLong() * decoded.height)),
                        ),
                    ),
                )
                if (outputScale < 0.999) {
                    val outputWidth = (decoded.width * outputScale).roundToInt().coerceAtLeast(1)
                    val outputHeight = (decoded.height * outputScale).roundToInt().coerceAtLeast(1)
                    val scaled = Bitmap.createScaledBitmap(decoded, outputWidth, outputHeight, true)
                    if (scaled !== decoded) {
                        decoded.recycle()
                        decoded = scaled
                    }
                }

                val part = safeChild(
                    sourceTileDirectory,
                    ".$tileKey.${UUID.randomUUID()}.part",
                )
                val partPath = part.canonicalPath
                activeWrites.add(partPath)
                try {
                    FileOutputStream(part).use { output ->
                        val format = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            Bitmap.CompressFormat.WEBP_LOSSY
                        } else {
                            @Suppress("DEPRECATION")
                            Bitmap.CompressFormat.WEBP
                        }
                        if (!decoded.compress(format, quality, output)) {
                            throw TileException("ENCODE_FAILED", "Tile encoding failed")
                        }
                        output.fd.sync()
                    }
                    replaceAtomically(part, target)
                } finally {
                    if (part.exists()) part.delete()
                    activeWrites.remove(partPath)
                }
                target.setLastModified(System.currentTimeMillis())
                prepared.touch()
                return tileResult(
                    sourceId = sourceId,
                    tileKey = tileKey,
                    target = target,
                    width = decoded.width,
                    height = decoded.height,
                    sampleSize = sampleSize,
                    x = x,
                    y = y,
                    sourceWidth = width,
                    sourceHeight = height,
                )
            } finally {
                if (!decoded.isRecycled) decoded.recycle()
            }
        }
    }

    private fun chooseSampleSize(width: Int, height: Int, targetWidth: Int): Int {
        var sample = 1
        while (sample < MAX_SAMPLE_SIZE) {
            val next = sample * 2
            val nextWidth = ceil(width.toDouble() / next).toInt()
            if (nextWidth < targetWidth) break
            sample = next
        }
        while (sample < MAX_SAMPLE_SIZE) {
            val decodedWidth = ceil(width.toDouble() / sample).toInt()
            val decodedHeight = ceil(height.toDouble() / sample).toInt()
            val pixels = decodedWidth.toLong() * decodedHeight
            if (decodedWidth <= MAX_DECODE_WIDTH &&
                decodedHeight <= MAX_DECODE_HEIGHT &&
                pixels <= MAX_DECODE_PIXELS
            ) {
                break
            }
            sample *= 2
        }
        val decodedWidth = ceil(width.toDouble() / sample).toInt()
        val decodedHeight = ceil(height.toDouble() / sample).toInt()
        if (decodedWidth > MAX_DECODE_WIDTH ||
            decodedHeight > MAX_DECODE_HEIGHT ||
            decodedWidth.toLong() * decodedHeight > MAX_DECODE_PIXELS
        ) {
            throw TileException("INVALID_RECT", "Requested tile cannot be decoded within memory limits")
        }
        return sample
    }

    private fun readCachedTile(file: File): SourceMetadata? {
        if (!file.isFile || file.length() == 0L) return null
        return try {
            inspectTile(file)
        } catch (_: Throwable) {
            file.delete()
            null
        }
    }

    private fun inspectTile(file: File): SourceMetadata {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) {
            throw TileException("CORRUPT_TILE", "Cached tile is invalid")
        }
        return SourceMetadata(options.outWidth, options.outHeight, options.outMimeType.orEmpty())
    }

    private fun tileResult(
        sourceId: String,
        tileKey: String,
        target: File,
        width: Int,
        height: Int,
        sampleSize: Int,
        x: Int,
        y: Int,
        sourceWidth: Int,
        sourceHeight: Int,
    ): Map<String, Any?> = mapOf(
        "sourceId" to sourceId,
        "tileKey" to tileKey,
        "path" to target.absolutePath,
        "width" to width,
        "height" to height,
        "sampleSize" to sampleSize,
        "sourceX" to x,
        "sourceY" to y,
        "sourceWidth" to sourceWidth,
        "sourceHeight" to sourceHeight,
    )

    private fun releaseSource(sourceId: String) {
        if (!SOURCE_ID_PATTERN.matches(sourceId)) {
            throw TileException("INVALID_SOURCE_ID", "Source id is invalid")
        }
        synchronized(registryLock) {
            val source = sources[sourceId] ?: return
            source.clientCount -= 1
            if (source.clientCount > 0) return
            sources.remove(sourceId, source)
            synchronized(source.lock) {
                source.released = true
                closeDecoder(source)
            }
        }
    }

    private fun closeDecoder(source: PreparedSource) {
        val decoder = source.decoder ?: return
        if (!decoder.isRecycled) decoder.recycle()
        source.decoder = null
    }

    private fun pruneCache(maxBytes: Long, maxAgeMs: Long): Map<String, Any?> {
        ensureDirectory(cacheRoot)
        val now = System.currentTimeMillis()
        val protectedPaths = sources.values
            .mapNotNull { source -> runCatching { source.file.canonicalPath }.getOrNull() }
            .toMutableSet()
            .apply { addAll(activeWrites) }
        val files = cacheRoot.walkTopDown()
            .filter { it.isFile }
            .filter { file ->
                val canonical = runCatching { file.canonicalPath }.getOrNull()
                canonical != null && canonical.startsWith(cacheRoot.canonicalPath + File.separator)
            }
            .toMutableList()
        var removedFiles = 0
        var removedBytes = 0L

        for (file in files.toList()) {
            val canonical = runCatching { file.canonicalPath }.getOrNull() ?: continue
            val isProtected = canonical in protectedPaths
            val stalePart = file.name.endsWith(".part") && now - file.lastModified() > 60L * 60L * 1000L
            val expired = now - file.lastModified() > maxAgeMs
            if (!isProtected && (stalePart || expired)) {
                val length = file.length()
                if (file.delete()) {
                    removedFiles += 1
                    removedBytes += length
                    files.remove(file)
                }
            }
        }

        var retainedBytes = files.sumOf { it.length() }
        if (retainedBytes > maxBytes) {
            for (file in files.sortedBy { it.lastModified() }) {
                if (retainedBytes <= maxBytes) break
                val canonical = runCatching { file.canonicalPath }.getOrNull() ?: continue
                if (canonical in protectedPaths) continue
                val length = file.length()
                if (file.delete()) {
                    retainedBytes -= length
                    removedFiles += 1
                    removedBytes += length
                }
            }
        }
        cacheRoot.walkBottomUp()
            .filter { it.isDirectory && it != cacheRoot }
            .forEach { directory -> directory.list()?.takeIf { it.isEmpty() }?.let { directory.delete() } }
        return mapOf(
            "removedFiles" to removedFiles,
            "removedBytes" to removedBytes,
            "retainedBytes" to retainedBytes.coerceAtLeast(0L),
        )
    }

    private fun requireSourceId(call: MethodCall): String {
        val value = requireString(call, "sourceId")
        if (!SOURCE_ID_PATTERN.matches(value)) {
            throw TileException("INVALID_SOURCE_ID", "Source id is invalid")
        }
        return value
    }

    private fun requireString(call: MethodCall, name: String): String {
        val value = call.argument<String>(name)?.trim().orEmpty()
        if (value.isEmpty()) throw TileException("INVALID_ARGUMENT", "$name is required")
        return value
    }

    private fun requireInt(call: MethodCall, name: String, minimum: Int): Int {
        val value = numberArgument(call, name)?.toInt()
            ?: throw TileException("INVALID_ARGUMENT", "$name is required")
        if (value < minimum) throw TileException("INVALID_ARGUMENT", "$name is invalid")
        return value
    }

    private fun numberArgument(call: MethodCall, name: String): Number? =
        call.argument<Number>(name)

    private fun validateSourceLength(length: Long) {
        if (length <= 0L) {
            throw TileException("UNSUPPORTED_IMAGE", "Image source is empty")
        }
        if (length > MAX_SOURCE_BYTES) {
            throw TileException("SOURCE_TOO_LARGE", "Image source exceeds the disk safety limit")
        }
    }

    private fun ensureAttached() {
        if (disposed.get()) {
            throw TileException("DETACHED", "Manga tile channel is detached")
        }
    }

    private fun isWithinDirectory(root: File, child: File): Boolean {
        val rootPath = root.path
        val childPath = child.path
        return childPath == rootPath || childPath.startsWith(rootPath + File.separator)
    }

    private fun validateHttpUri(value: String, errorCode: String) {
        val uri = runCatching { URI(value) }.getOrNull()
            ?: throw TileException(errorCode, "URL is invalid")
        if (!uri.isAbsolute || uri.host.isNullOrBlank() || uri.scheme.lowercase() !in setOf("http", "https")) {
            throw TileException(errorCode, "Only HTTP(S) URLs are accepted")
        }
        if (!uri.rawUserInfo.isNullOrBlank()) {
            throw TileException(errorCode, "URL credentials are not allowed")
        }
    }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte) }

    private fun ensureDirectory(directory: File) {
        if (directory.isDirectory) return
        if (!directory.mkdirs() && !directory.isDirectory) {
            throw TileException("CACHE_UNAVAILABLE", "Cannot create manga tile cache")
        }
    }

    private fun safeChild(parent: File, name: String): File {
        if (name.contains('/') || name.contains('\\') || name == "." || name == "..") {
            throw TileException("INVALID_CACHE_PATH", "Cache path is invalid")
        }
        val canonicalParent = parent.canonicalFile
        val child = File(canonicalParent, name).canonicalFile
        if (child.parentFile != canonicalParent) {
            throw TileException("INVALID_CACHE_PATH", "Cache path escapes its root")
        }
        return child
    }

    private fun replaceAtomically(part: File, target: File) {
        ensureDirectory(target.parentFile ?: cacheRoot)
        if (target.exists() && !target.delete()) {
            throw TileException("CACHE_WRITE_FAILED", "Cannot replace cached tile")
        }
        if (!part.renameTo(target)) {
            throw TileException("CACHE_WRITE_FAILED", "Cannot finalize cached tile")
        }
    }

    private data class ResolvedSource(
        val sourceId: String,
        val file: File,
        val localInput: Boolean,
    )

    private data class SourceMetadata(
        val width: Int,
        val height: Int,
        val mimeType: String,
    )

    private data class PreparedSource(
        val sourceId: String,
        val file: File,
        val width: Int,
        val height: Int,
        val mimeType: String,
        val byteLength: Long,
        val localInput: Boolean,
        val lock: Any = Any(),
        var clientCount: Int = 1,
        var decoder: BitmapRegionDecoder? = null,
        var released: Boolean = false,
    ) {
        fun touch() {
            if (!localInput) file.setLastModified(System.currentTimeMillis())
        }

        fun toMap(): Map<String, Any?> = mapOf(
            "sourceId" to sourceId,
            "width" to width,
            "height" to height,
            "mimeType" to mimeType,
            "byteLength" to byteLength,
            "localInput" to localInput,
        )
    }

    private class TileException(
        val code: String,
        override val message: String,
    ) : Exception(message)

    private class TileThreadFactory : ThreadFactory {
        private var index = 0

        override fun newThread(task: Runnable): Thread = Thread(
            task,
            "manga-tile-${++index}",
        ).apply {
            priority = Thread.NORM_PRIORITY - 1
            isDaemon = true
        }
    }
}
