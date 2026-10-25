package org.neforum.neforum_app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * "neforum/share" (lib/platform/share_target.dart): shares a hand-off's
 * files and caption straight into one app, the plan's Android package
 * (ACTION_SEND for one file or none, ACTION_SEND_MULTIPLE for several, aimed
 * with setPackage). The caption goes in EXTRA_TEXT; the app also put it on
 * the clipboard. Files go out as HandoffFileProvider addresses with a read
 * grant. When the app is not installed (or takes no such share), the system
 * share sheet opens instead. Answers "app" or "chooser".
 */
class ShareChannel(private val activity: Activity) {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "neforum/share").setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "share") {
            result.notImplemented()
            return
        }
        val pkg = call.argument<String>("package")
        val paths = call.argument<List<String>>("paths") ?: emptyList()
        val types = call.argument<List<String>>("mimeTypes") ?: emptyList()
        val text = call.argument<String>("text")
        val uris = try {
            paths.map { HandoffFileProvider.uriFor(activity, File(it)) }
        } catch (e: Exception) {
            result.error("file", e.message ?: "A file could not be shared.", null)
            return
        }
        val send = sendIntent(uris, types, text)
        if (!pkg.isNullOrEmpty()) {
            try {
                activity.startActivity(Intent(send).setPackage(pkg))
                result.success("app")
                return
            } catch (e: ActivityNotFoundException) {
                // Not installed, or it takes no such share: the share sheet.
            }
        }
        try {
            activity.startActivity(Intent.createChooser(send, null))
            result.success("chooser")
        } catch (e: ActivityNotFoundException) {
            result.error("share", "No app on this phone can take this post.", null)
        }
    }

    private fun sendIntent(uris: List<Uri>, types: List<String>, text: String?): Intent {
        val intent = when {
            uris.size > 1 -> Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            uris.size == 1 -> Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
            else -> Intent(Intent.ACTION_SEND)
        }
        intent.type = commonType(types, uris.isEmpty())
        if (!text.isNullOrEmpty()) intent.putExtra(Intent.EXTRA_TEXT, text)
        if (uris.isNotEmpty()) {
            // The grant travels with the clip, also through the share sheet.
            val clip = ClipData.newRawUri(null, uris[0])
            for (uri in uris.drop(1)) clip.addItem(ClipData.Item(uri))
            intent.clipData = clip
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return intent
    }

    companion object {
        // The type of the share: text/plain without files; else the files'
        // own type when they all have one, else their family with a
        // wildcard subtype (all images, all videos), else any type.
        fun commonType(types: List<String>, textOnly: Boolean): String {
            if (textOnly) return "text/plain"
            val distinct = types.map { it.lowercase() }.distinct()
            if (distinct.size == 1) return distinct[0]
            val families = distinct.map { it.substringBefore('/') }.distinct()
            return if (families.size == 1 && families[0].isNotEmpty()) "${families[0]}/*" else "*/*"
        }
    }
}
