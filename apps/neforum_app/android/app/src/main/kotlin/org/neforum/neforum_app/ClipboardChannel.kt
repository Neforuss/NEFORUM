package org.neforum.neforum_app

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * "neforum/clipboard" on Android (lib/platform/clipboard_media.dart): puts a
 * hand-off photo on the clipboard, so it can be pasted into another app that
 * takes pasted pictures. The PNG is written to NEFORUM's cache (replacing the
 * previous one) and the clipboard holds its HandoffFileProvider address;
 * Android lets the app that pastes it read it. Answers true when it is on
 * the clipboard.
 */
class ClipboardChannel(private val activity: Activity) {
    private val io = Executors.newSingleThreadExecutor()

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "neforum/clipboard").setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "copyImage" -> copyImage(call, result)
            else -> result.notImplemented()
        }
    }

    private fun copyImage(call: MethodCall, result: MethodChannel.Result) {
        val png = call.argument<ByteArray>("png")
        if (png == null || png.isEmpty()) {
            result.success(false)
            return
        }
        io.execute {
            val file = try {
                val folder = File(activity.cacheDir, "clipboard").apply { mkdirs() }
                folder.listFiles()?.forEach { it.delete() }
                File(folder, "photo-${System.currentTimeMillis()}.png").apply { writeBytes(png) }
            } catch (e: Exception) {
                null
            }
            activity.runOnUiThread {
                if (file == null) {
                    result.success(false)
                    return@runOnUiThread
                }
                try {
                    val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    val uri = HandoffFileProvider.uriFor(activity, file)
                    clipboard.setPrimaryClip(ClipData.newUri(activity.contentResolver, "Photo", uri))
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
        }
    }
}
