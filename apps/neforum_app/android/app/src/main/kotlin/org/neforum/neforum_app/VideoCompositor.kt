package org.neforum.neforum_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.media.MediaCodecList
import android.media.MediaMetadataRetriever
import android.net.Uri
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
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import com.google.common.collect.ImmutableList
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
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
                val supported = hasH264Encoder()
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
            else -> result.notImplemented()
        }
    }

    private fun hasH264Encoder(): Boolean = try {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(MimeTypes.VIDEO_H264, ignoreCase = true) }
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
        if (running != null) {
            result.error("busy", "Another video is being made.", null)
            return
        }
        File(output).delete()
        val effects = Effects(
            emptyList<AudioProcessor>(),
            listOf<Effect>(
                PlaceInFrame(width, height, video),
                OverlayEffect(ImmutableList.of<TextureOverlay>(BitmapOverlay.createStaticBitmapOverlay(overlay))),
            ),
        )
        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(input)))).setEffects(effects).build()
        val progress = ProgressHolder()
        lateinit var transformer: Transformer
        lateinit var poll: Runnable

        fun finish(error: ExportException?) {
            if (running !== transformer) return
            running = null
            main.removeCallbacks(poll)
            if (error == null) {
                result.success(null)
            } else {
                File(output).delete()
                result.error("compose", "The video could not be made (${error.errorCodeName}).", null)
            }
        }

        transformer = Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) = finish(null)

                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) =
                    finish(exportException)
            })
            .build()
        poll = Runnable {
            if (running !== transformer) return@Runnable
            if (transformer.getProgress(progress) == Transformer.PROGRESS_STATE_AVAILABLE) {
                channel.invokeMethod("progress", mapOf("id" to id, "progress" to progress.progress / 100.0))
            }
            main.postDelayed(poll, PROGRESS_INTERVAL_MS)
        }
        running = transformer
        try {
            transformer.start(item, output)
        } catch (e: Exception) {
            running = null
            File(output).delete()
            result.error("compose", "The video could not be started: ${e.message ?: e}", null)
            return
        }
        main.postDelayed(poll, PROGRESS_INTERVAL_MS)
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
