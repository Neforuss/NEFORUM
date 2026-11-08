package org.neforum.neforum_app

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * "neforum/notification_access" on Android (lib/platform/notification_access.dart):
 * what the notification plugin cannot tell. Whether Android would still show
 * its permission dialog, and whether the user set the results channel to none.
 * It needs an Activity, so it is missing in a background engine, where Dart
 * treats access as unread.
 */
class NotificationAccessChannel(private val activity: Activity) {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "read" -> result.success(read())
            "openResultsChannelSettings" -> openResultsChannelSettings(result)
            else -> result.notImplemented()
        }
    }

    private fun read(): Map<String, Any> {
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val rationale = Build.VERSION.SDK_INT >= 33 &&
            activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
        val resultsOff = Build.VERSION.SDK_INT >= 26 &&
            manager.getNotificationChannel(RESULTS_CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "enabled" to manager.areNotificationsEnabled(),
            "rationale" to rationale,
            "resultsChannelOff" to resultsOff,
        )
    }

    private fun openResultsChannelSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 26) {
            result.error("unsupported", "This Android has no notification channels.", null)
            return
        }
        try {
            activity.startActivity(
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, RESULTS_CHANNEL)
            )
            result.success(null)
        } catch (e: Exception) {
            result.error("settings", e.message ?: e.toString(), null)
        }
    }

    companion object {
        const val NAME = "neforum/notification_access"

        /** _channelResults in lib/platform/notifications.dart. */
        private const val RESULTS_CHANNEL ="neforum.results"
    }
}
