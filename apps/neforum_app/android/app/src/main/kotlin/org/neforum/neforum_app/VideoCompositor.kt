package org.neforum.neforum_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.media.MediaCodecList
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.MatrixTransformation
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.google.common.collect.ImmutableList
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * "neforum/video": the video caption compositor (lib/platform/video_compositor.dart).
 * Media3 Transformer re-encodes the video as H.264 and AAC in an MP4 of the
 * requested frame. Transformer turns the picture upright from its rotation
 * metadata; [PlaceInFrame] then puts it into the video rectangle of a
 * frame-sized canvas, and an [OverlayEffect] draws one frame-sized bitmap over
 * everything: the background colour around the picture, the caption on top.
 * Portrait frames come out stored landscape with rotation 90, which players
 * and the networks show upright (Transformer does this for encoder support).
 *
 * The same channel reads preview frames with MediaMetadataRetriever and runs
 * the other Transformer exports through [export]: transcode (a [Presentation]
 * scale and requested encoder bitrates), audioVideo (a still picture sequence
 * beside the sound's sequence) and transcodeAudio (the sound alone as AAC).
 */
@OptIn(UnstableApi::class)
class VideoCompositor(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "neforum/video")
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** The export in progress (Dart sends one at a time); main thread only. */
    private var running: Transformer? = null

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> io.execute {
                val supported = hasEncoder(MimeTypes.VIDEO_H264)
                main.post { result.success(supported) }
            }
            "probe" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("args", "No video was given.", null)
                    return
                }
                io.execute {
                    val probe = try {
                        probe(path)
                    } catch (e: Exception) {
                        null
                    }
                    main.post {
                        if (probe == null) result.error("probe", "NEFORUM could not read this video.", null)
                        else result.success(probe)
                    }
                }
            }
            "compose" -> compose(call, result)
            "frame" -> frame(call, result)
            "transcode" -> transcode(call, result)
            "audioVideo" -> audioVideo(call, result)
            "audioFormats" -> io.execute {
                // Android encodes AAC but has no MP3 encoder.
                val formats = if (hasEncoder(MimeTypes.AUDIO_AAC)) listOf("m4a") else emptyList()
                main.post { result.success(formats) }
            }
            "transcodeAudio" -> transcodeAudio(call, result)
            else -> result.notImplemented()
        }
    }

    private fun hasEncoder(mimeType: String): Boolean = try {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(mimeType, ignoreCase = true) }
        }
    } catch (e: Exception) {
        false
    }

    /** Stored size, clockwise rotation, duration and sound, from the file's metadata. */
    private fun probe(path: String): Map<String, Any> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            fun number(key: Int) = retriever.extractMetadata(key)?.toLongOrNull() ?: 0L
            val width = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH).toInt()
            val height = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT).toInt()
            if (width <= 0 || height <= 0) throw IllegalArgumentException("This file has no video.")
            return mapOf(
                "width" to width,
                "height" to height,
                "rotation" to number(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION).toInt(),
                "durationMs" to number(MediaMetadataRetriever.METADATA_KEY_DURATION),
                "hasAudio" to (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"),
            )
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {
                // Already gone.
            }
        }
    }

    private fun compose(call: MethodCall, result: MethodChannel.Result) {
        fun int(key: String) = call.argument<Number>(key)?.toInt() ?: 0
        val input = call.argument<String>("inputPath").orEmpty()
        val output = call.argument<String>("outputPath").orEmpty()
        val png = call.argument<ByteArray>("overlayPng")
        val width = int("frameWidth")
        val height = int("frameHeight")
        val video = Rect(int("videoLeft"), int("videoTop"), int("videoLeft") + int("videoWidth"), int("videoTop") + int("videoHeight"))
        val background = int("backgroundRgb") or 0xFF000000.toInt()
        val id = call.argument<Number>("id")?.toLong() ?: 0L
        val frameOk = width in 16..4096 && height in 16..4096 && width % 2 == 0 && height % 2 == 0
        val videoOk = !video.isEmpty && video.left >= 0 && video.top >= 0 && video.right <= width && video.bottom <= height
        if (!frameOk || !videoOk || png == null || png.isEmpty() || input.isEmpty() || output.isEmpty() || input == output) {
            result.error("args", "The video request is not complete.", null)
            return
        }
        if (running != null) {
            result.error("busy", "Another video is being made.", null)
            return
        }
        io.execute {
            val overlay = try {
                frameOverlay(png, width, height, video, background)
            } catch (e: Exception) {
                null
            }
            main.post {
                if (overlay == null) {
                    result.error("compose", "The caption image could not be read.", null)
                } else {
                    start(id, input, output, overlay, width, height, video, result)
                }
            }
        }
    }

    private fun start(
        id: Long,
        input: String,
        output: String,
        overlay: Bitmap,
        width: Int,
        height: Int,
        video: Rect,
        result: MethodChannel.Result,
    ) {
        val effects = Effects(
            emptyList<AudioProcessor>(),
            listOf<Effect>(
                PlaceInFrame(width, height, video),
                OverlayEffect(ImmutableList.of<TextureOverlay>(BitmapOverlay.createStaticBitmapOverlay(overlay))),
            ),
        )
        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(input)))).setEffects(effects).build()
        export(id, output, "compose", "video", result) { it.start(item, output) }
    }

    /**
     * Runs one Transformer export to [output] with progress under [id]: the
     * shared end of compose, transcode, audioVideo and transcodeAudio. Errors
     * report [errorCode] and name the [subject] being made; [cleanup] runs
     * however the export ends, and a failed one leaves no file.
     */
    private fun export(
        id: Long,
        output: String,
        errorCode: String,
        subject: String,
        result: MethodChannel.Result,
        encoderFactory: DefaultEncoderFactory? = null,
        cleanup: () -> Unit = {},
        begin: (Transformer) -> Unit,
    ) {
        if (running != null) {
            cleanup()
            result.error("busy", "Another video is being made.", null)
            return
        }
        File(output).delete()
        val progress = ProgressHolder()
        lateinit var transformer: Transformer
        lateinit var poll: Runnable

        fun finish(error: ExportException?) {
            if (running !== transformer) return
            running = null
            main.removeCallbacks(poll)
            cleanup()
            if (error == null) {
                result.success(null)
            } else {
                File(output).delete()
                result.error(errorCode, "The $subject could not be made (${error.errorCodeName}).", null)
            }
        }

        val builder = Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) = finish(null)

                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) =
                    finish(exportException)
            })
        if (encoderFactory != null) builder.setEncoderFactory(encoderFactory)
        transformer = builder.build()
        poll = Runnable {
            if (running !== transformer) return@Runnable
            if (transformer.getProgress(progress) == Transformer.PROGRESS_STATE_AVAILABLE) {
                channel.invokeMethod("progress", mapOf("id" to id, "progress" to progress.progress / 100.0))
            }
            main.postDelayed(poll, PROGRESS_INTERVAL_MS)
        }
        running = transformer
        try {
            begin(transformer)
        } catch (e: Exception) {
            running = null
            cleanup()
            File(output).delete()
            result.error(errorCode, "The $subject could not be started: ${e.message ?: e}", null)
            return
        }
        main.postDelayed(poll, PROGRESS_INTERVAL_MS)
    }

    /**
     * Encoders at the requested bitrates: [videoBitrate] (when given) for
     * H.264, kept to the encoder's range by Media3's fallback, and
     * [audioBitrate] for AAC, kept here to what AAC encoders take. Requested
     * settings also make Transformer re-encode tracks it would otherwise copy.
     */
    private fun encoders(audioBitrate: Int, videoBitrate: Int? = null): DefaultEncoderFactory {
        val builder = DefaultEncoderFactory.Builder(context).setRequestedAudioEncoderSettings(
            AudioEncoderSettings.Builder().setBitrate(audioBitrate.coerceIn(MIN_AUDIO_BITRATE, MAX_AUDIO_BITRATE)).build(),
        )
        if (videoBitrate != null) {
            builder.setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(videoBitrate).build())
        }
        return builder.build()
    }

    // Frames

    private fun frame(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val position = maxOf(0L, call.argument<Number>("positionMs")?.toLong() ?: 0L)
        val maxSide = (call.argument<Number>("maxSide")?.toInt() ?: 512).coerceIn(16, 4096)
        if (path.isNullOrEmpty()) {
            result.error("args", "No video was given.", null)
            return
        }
        io.execute {
            val frame = try {
                frame(path, position, maxSide)
            } catch (e: Exception) {
                null
            }
            main.post {
                if (frame == null) result.error("frame", "NEFORUM could not read a frame of this video.", null)
                else result.success(frame)
            }
        }
    }

    /**
     * An upright PNG of the frame nearest [positionMs], at most [maxSide] on
     * its longest side. MediaMetadataRetriever turns frames upright itself,
     * and its scaled frames fit a box given in the upright orientation.
     */
    private fun frame(path: String, positionMs: Long, maxSide: Int): Map<String, Any> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            fun number(key: Int) = retriever.extractMetadata(key)?.toLongOrNull() ?: 0L
            val longest = maxOf(
                number(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH),
                number(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT),
            ).toInt()
            if (longest <= 0) throw IllegalArgumentException("This file has no video.")
            val durationMs = number(MediaMetadataRetriever.METADATA_KEY_DURATION)
            val at = if (durationMs > 0) minOf(positionMs, durationMs) else positionMs
            // A square box, never larger than the video: scaled frames also grow.
            val box = minOf(maxSide, longest)
            fun grab(option: Int): Bitmap? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    retriever.getScaledFrameAtTime(at * 1000, option, box, box)
                } else {
                    retriever.getFrameAtTime(at * 1000, option)
                }
            // Past the last frame, the closest one may not decode; the sync frame before it does.
            val frame = grab(MediaMetadataRetriever.OPTION_CLOSEST)
                ?: grab(MediaMetadataRetriever.OPTION_PREVIOUS_SYNC)
                ?: throw IllegalStateException("No frame at $at ms.")
            val shown = fitted(frame, maxSide)
            val png = ByteArrayOutputStream().use { stream ->
                shown.compress(Bitmap.CompressFormat.PNG, 100, stream)
                stream.toByteArray()
            }
            val answer = mapOf<String, Any>("png" to png, "width" to shown.width, "height" to shown.height, "positionMs" to at)
            if (shown !== frame) shown.recycle()
            frame.recycle()
            return answer
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {
                // Already gone.
            }
        }
    }

    /** [bitmap] scaled down so its longest side is at most [maxSide]; itself when it already fits. */
    private fun fitted(bitmap: Bitmap, maxSide: Int): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= maxSide) return bitmap
        val scale = maxSide.toDouble() / longest
        val width = Math.round(bitmap.width * scale).toInt().coerceIn(1, maxSide)
        val height = Math.round(bitmap.height * scale).toInt().coerceIn(1, maxSide)
        return Bitmap.createScaledBitmap(bitmap, width, height, true)
    }

    // Re-encoding

    private fun transcode(call: MethodCall, result: MethodChannel.Result) {
        fun int(key: String) = call.argument<Number>(key)?.toInt() ?: 0
        val input = call.argument<String>("inputPath").orEmpty()
        val output = call.argument<String>("outputPath").orEmpty()
        val videoBitrate = int("videoBitrate")
        val audioBitrate = int("audioBitrate")
        val maxSide = int("maxSide")
        val id = call.argument<Number>("id")?.toLong() ?: 0L
        if (input.isEmpty() || output.isEmpty() || input == output || videoBitrate <= 0 || maxSide !in 16..4096) {
            result.error("args", "The video request is not complete.", null)
            return
        }
        if (running != null) {
            result.error("busy", "Another video is being made.", null)
            return
        }
        io.execute {
            val size = try {
                scaledShownSize(input, maxSide)
            } catch (e: Exception) {
                null
            }
            main.post {
                if (size == null) {
                    result.error("probe", "NEFORUM could not read this video.", null)
                    return@post
                }
                // Transformer turns the picture upright before the effects, so
                // the size is the shown one.
                val effects = Effects(
                    emptyList<AudioProcessor>(),
                    listOf<Effect>(Presentation.createForWidthAndHeight(size.width, size.height, Presentation.LAYOUT_STRETCH_TO_FIT)),
                )
                val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(input)))).setEffects(effects).build()
                export(id, output, "transcode", "video", result, encoders(audioBitrate, videoBitrate)) { it.start(item, output) }
            }
        }
    }

    /**
     * The video's shown size (rotation applied), scaled down so its longest
     * side is at most [maxSide], on even sides for the encoder.
     */
    private fun scaledShownSize(path: String, maxSide: Int): Size {
        val probe = probe(path)
        val stored = Size(probe["width"] as Int, probe["height"] as Int)
        val turned = ((probe["rotation"] as Int) % 180 + 180) % 180 == 90
        val width = if (turned) stored.height else stored.width
        val height = if (turned) stored.width else stored.height
        val scale = minOf(1.0, maxSide.toDouble() / maxOf(width, height))
        fun even(side: Int): Int {
            val scaled = Math.round(side * scale).toInt().coerceIn(2, maxSide)
            return scaled - scaled % 2
        }
        return Size(even(width), even(height))
    }

    private fun audioVideo(call: MethodCall, result: MethodChannel.Result) {
        fun int(key: String) = call.argument<Number>(key)?.toInt() ?: 0
        val audio = call.argument<String>("audioPath").orEmpty()
        val output = call.argument<String>("outputPath").orEmpty()
        val png = call.argument<ByteArray>("imagePng")
        val width = int("frameWidth")
        val height = int("frameHeight")
        val audioBitrate = int("audioBitrate")
        val id = call.argument<Number>("id")?.toLong() ?: 0L
        val frameOk = width in 16..4096 && height in 16..4096 && width % 2 == 0 && height % 2 == 0
        if (!frameOk || png == null || png.isEmpty() || audio.isEmpty() || output.isEmpty() || audio == output) {
            result.error("args", "The video request is not complete.", null)
            return
        }
        if (running != null) {
            result.error("busy", "Another video is being made.", null)
            return
        }
        io.execute {
            val durationMs = try {
                soundDurationMs(audio)
            } catch (e: Exception) {
                0L
            }
            val still = File(context.cacheDir, "neforum-still-$id.png")
            val stillOk = durationMs > 0 && try {
                writeStill(png, width, height, still)
                true
            } catch (e: Exception) {
                still.delete()
                false
            }
            main.post {
                if (durationMs <= 0) {
                    result.error("probe", "NEFORUM could not read this sound file.", null)
                    return@post
                }
                if (!stillOk) {
                    result.error("audioVideo", "The picture could not be read.", null)
                    return@post
                }
                // The picture for the length of the sound, in a sequence of
                // its own beside the sound's.
                val picture = EditedMediaItem.Builder(
                    MediaItem.Builder()
                        .setUri(Uri.fromFile(still))
                        .setMimeType(MimeTypes.IMAGE_PNG)
                        .setImageDurationMs(durationMs)
                        .build(),
                )
                    .setFrameRate(STILL_FRAME_RATE)
                    .setEffects(
                        Effects(
                            emptyList<AudioProcessor>(),
                            listOf<Effect>(Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT)),
                        ),
                    )
                    .build()
                val sound = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(audio)))).setRemoveVideo(true).build()
                val composition = Composition.Builder(
                    EditedMediaItemSequence.Builder(picture).build(),
                    EditedMediaItemSequence.Builder(sound).build(),
                ).build()
                export(id, output, "audioVideo", "video", result, encoders(audioBitrate), cleanup = { still.delete() }) {
                    it.start(composition, output)
                }
            }
        }
    }

    private fun soundDurationMs(path: String): Long {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            return retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {
                // Already gone.
            }
        }
    }

    /** [png] stretched over a [width] x [height] black frame, written to [file]. */
    private fun writeStill(png: ByteArray, width: Int, height: Int, file: File) {
        val picture = BitmapFactory.decodeByteArray(png, 0, png.size) ?: throw IllegalArgumentException("Not an image.")
        val frame = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(frame).apply {
            // Video has no transparency: clear parts of the picture show black.
            drawColor(Color.BLACK)
            drawBitmap(picture, null, Rect(0, 0, width, height), Paint(Paint.FILTER_BITMAP_FLAG))
        }
        picture.recycle()
        try {
            FileOutputStream(file).use { stream ->
                if (!frame.compress(Bitmap.CompressFormat.PNG, 100, stream)) throw IllegalStateException("The picture could not be saved.")
            }
        } finally {
            frame.recycle()
        }
    }

    private fun transcodeAudio(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("inputPath").orEmpty()
        val output = call.argument<String>("outputPath").orEmpty()
        val format = call.argument<String>("format").orEmpty()
        val bitrate = call.argument<Number>("bitrate")?.toInt() ?: 0
        val id = call.argument<Number>("id")?.toLong() ?: 0L
        if (format == "mp3") {
            result.error("unsupported", "This device cannot write MP3 files.", null)
            return
        }
        if (format != "m4a" || input.isEmpty() || output.isEmpty() || input == output) {
            result.error("args", "The sound request is not complete.", null)
            return
        }
        // Only the sound: a cover picture or video track is left out.
        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(input)))).setRemoveVideo(true).build()
        export(id, output, "transcodeAudio", "sound file", result, encoders(bitrate)) { it.start(item, output) }
    }

    /**
     * The frame-sized bitmap drawn over every frame: the background colour
     * except in the video rectangle, then the caption PNG stretched over the
     * whole frame. Media3's overlay shader blends straight colours
     * (overlay * alpha + video * (1 - alpha)), while Android bitmaps hold
     * premultiplied ones, so the pixels are divided by their alpha first and
     * written back raw.
     */
    private fun frameOverlay(png: ByteArray, width: Int, height: Int, video: Rect, background: Int): Bitmap {
        val caption = BitmapFactory.decodeByteArray(png, 0, png.size) ?: throw IllegalArgumentException("Not an image.")
        val frame = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(frame).apply {
            drawColor(background)
            drawRect(video, Paint().apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR) })
            drawBitmap(caption, null, Rect(0, 0, width, height), Paint(Paint.FILTER_BITMAP_FLAG))
        }
        caption.recycle()
        val pixels = ByteBuffer.allocate(frame.byteCount)
        frame.copyPixelsToBuffer(pixels)
        val bytes = pixels.array()
        // RGBA bytes; only partly transparent pixels change.
        for (i in bytes.indices step 4) {
            val alpha = bytes[i + 3].toInt() and 0xFF
            if (alpha == 0 || alpha == 255) continue
            for (c in 0..2) {
                val value = bytes[i + c].toInt() and 0xFF
                bytes[i + c] = minOf(255, (value * 255 + alpha / 2) / alpha).toByte()
            }
        }
        pixels.rewind()
        frame.copyPixelsFromBuffer(pixels)
        return frame
    }

    private companion object {
        const val PROGRESS_INTERVAL_MS = 250L

        /** Still pictures are written at a rate every network accepts. */
        const val STILL_FRAME_RATE = 30

        /** AAC bitrates Android's encoders take at 44.1 and 48 kHz, mono or stereo. */
        const val MIN_AUDIO_BITRATE = 32_000
        const val MAX_AUDIO_BITRATE = 320_000
    }
}

/**
 * Turns the canvas into a [width] x [height] frame and puts the whole picture
 * into [video] (frame pixels), stretched: the Dart side gives a rectangle with
 * the picture's aspect. Matrices work in normalized coordinates, -1 to 1 with
 * y up; the rest of the frame stays transparent for the overlay to fill.
 */
@OptIn(UnstableApi::class)
private class PlaceInFrame(private val width: Int, private val height: Int, video: Rect) : MatrixTransformation {
    private val matrix = Matrix().apply {
        setScale(video.width().toFloat() / width, video.height().toFloat() / height)
        postTranslate((video.left + video.right).toFloat() / width - 1f, 1f - (video.top + video.bottom).toFloat() / height)
    }

    override fun configure(inputWidth: Int, inputHeight: Int): Size = Size(width, height)

    override fun getMatrix(presentationTimeUs: Long): Matrix = matrix
}
