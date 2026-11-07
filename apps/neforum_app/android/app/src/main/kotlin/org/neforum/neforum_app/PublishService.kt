package org.neforum.neforum_app

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps the process alive for a publish run, which itself goes on in Dart. It starts
 * from a tap, shows the run's progress and offers Cancel. No work happens here.
 *
 * Android's Recents path spares a process with a foreground service, so the service
 * and the retained engine (PublishHost) outlive a swipe. `dataSync` allows 6 hours
 * after leaving the app on Android 15+; returning resets it, and [onTimeout] ends it.
 */
class PublishService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Posting now", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Progress of a post going out"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> {
                PublishHost.cancelAll()
                if (!isForeground) stopSelf()
                return START_NOT_STICKY
            }
            ACTION_DISMISSED -> {
                PublishHost.dismissed = true
                if (!isForeground) stopSelf()
                return START_NOT_STICKY
            }
        }
        try {
            // First thing: Android gives a started service seconds for this.
            ServiceCompat.startForeground(this, NOTIFICATION_ID, build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            isForeground = true
            rearmWakeLock()
            PublishHost.serviceStarted(true)
            // The run ended before Android got here. The promise above had to be kept
            // first: stopping without it is fatal.
            if (!PublishHost.runActive) stopNow()
        } catch (e: Exception) {
            // The time limit is used up, or Android refused for another reason.
            Log.w(TAG, "No foreground: ${e.javaClass.simpleName}")
            PublishHost.serviceStarted(false)
            stopSelf()
        }
        // Not sticky: a restarted service has no Dart run to keep; recovery settles it.
        return START_NOT_STICKY
    }

    /** Android 15+: a few seconds to stop, or a fatal exception. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "publish-timeout type=$fgsType")
        PublishHost.timedOut()
        stopNow()
    }

    /** Nothing to do on a swipe: the service stays, and with it the engine. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "publish-task-removed active=${PublishHost.runActive}")
    }

    override fun onDestroy() {
        releaseWakeLock()
        isForeground = false
        instance = null
        super.onDestroy()
    }

    private fun stopNow() {
        isForeground = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        releaseWakeLock()
        stopSelf()
    }

    /**
     * Without this the CPU can sleep with the screen off and the upload waits for the
     * person to wake the phone. Every update re-arms it, so a run that hangs loses it
     * after the timeout rather than holding the phone awake for ever.
     */
    private fun rearmWakeLock() {
        val lock = wakeLock ?: getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            .also {
                it.setReferenceCounted(false)
                wakeLock = it
            }
        lock.acquire(WAKE_LOCK_TIMEOUT_MS)
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    @SuppressLint("MissingPermission")
    private fun showNow() {
        if (!isForeground) return
        rearmWakeLock()
        if (PublishHost.dismissed) return
        // With notifications refused this shows nothing and the service still runs.
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, build())
    }

    private fun build(): Notification = buildPublishNotification(this)

    companion object {
        private const val TAG = "PublishService"
        private const val WAKE_LOCK_TAG = "neforum:publish"
        private const val WAKE_LOCK_TIMEOUT_MS = 30L * 60L * 1000L
        const val CHANNEL_ID = "neforum.progress"
        const val NOTIFICATION_ID = 41
        const val ACTION_CANCEL = "org.neforum.publish.CANCEL"
        const val ACTION_DISMISSED = "org.neforum.publish.DISMISSED"

        private var instance: PublishService? = null

        var isForeground = false
            private set

        fun show() {
            instance?.showNow()
        }

        fun finish() {
            instance?.stopNow()
        }
    }
}

/** The run's notification. Every word comes from Dart's snapshot, none is the post's text. */
private fun buildPublishNotification(context: Context): Notification {
    val snapshot = PublishHost.snapshot()
    val headline = snapshot?.get("headline") as? String ?: "Getting your post ready"
    val detail = snapshot?.get("detail") as? String
    val permille = (snapshot?.get("postPermille") as? Number)?.toInt()
    val builder = NotificationCompat.Builder(context, PublishService.CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_neforum)
        .setColor(BRAND_COLOR)
        .setContentTitle(headline)
        .setContentText(detail)
        .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setSilent(true)
        .setShowWhen(false)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setContentIntent(openIntent(context))
        .setDeleteIntent(serviceIntent(context, PublishService.ACTION_DISMISSED, 2))
        .addAction(0, "Cancel", serviceIntent(context, PublishService.ACTION_CANCEL, 1))
    if (Build.VERSION.SDK_INT >= 36) {
        builder.setStyle(progressStyle(snapshot, permille))
        builder.setRequestPromotedOngoing(true)
        if (permille != null) builder.setShortCriticalText("${permille / 10}%")
    } else {
        builder.setProgress(PERMILLE_MAX, permille ?: 0, permille == null)
    }
    return builder.build()
}

/**
 * One segment per network, sized by its share of the bytes, with its colour once it
 * has an outcome. Android drops segments past 15 and points past 4, and dropping one
 * would shift the whole bar, so a run with more shows a single segment.
 */
private fun progressStyle(snapshot: Map<*, *>?, permille: Int?): NotificationCompat.ProgressStyle {
    val style = NotificationCompat.ProgressStyle().setStyledByProgress(true)
    if (permille == null) return style.setProgressIndeterminate(true)
    val networks = PublishHost.networks()
    val total = networks.sumOf { maxOf(it.bytes, 1L) }
    if (networks.isEmpty() || networks.size > MAX_SEGMENTS) {
        return style
            .addProgressSegment(NotificationCompat.ProgressStyle.Segment(PERMILLE_MAX))
            .setProgress(permille)
    }
    val states = (snapshot?.get("networks") as? List<*>)
        ?.mapNotNull { it as? Map<*, *> }
        ?.associate { (it["id"] as? String) to (it["state"] as? String) }
        ?: emptyMap()
    var position = 0
    networks.forEachIndexed { index, network ->
        val length = maxOf(1L, maxOf(network.bytes, 1L) * PERMILLE_MAX / total).toInt()
        val segment = NotificationCompat.ProgressStyle.Segment(length)
        when (states[network.id]) {
            "posted" -> segment.setColor(COLOR_POSTED)
            "failed" -> segment.setColor(COLOR_FAILED)
        }
        style.addProgressSegment(segment)
        position += length
        if (index < networks.size - 1 && networks.size - 1 <= MAX_POINTS) {
            style.addProgressPoint(NotificationCompat.ProgressStyle.Point(position))
        }
    }
    // The parts round, so the sum is rarely exactly the permille scale.
    return style.setProgress(permille * position / PERMILLE_MAX)
}

private fun openIntent(context: Context): PendingIntent {
    val open = Intent(context, MainActivity::class.java).apply {
        action = MainActivity.ACTION_OPEN_POST
        putExtra(MainActivity.EXTRA_POST_ID, PublishHost.firstPost())
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
    return PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
}

private fun serviceIntent(context: Context, action: String, requestCode: Int): PendingIntent =
    PendingIntent.getService(
        context,
        requestCode,
        Intent(context, PublishService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

private const val PERMILLE_MAX = 1000
private const val MAX_SEGMENTS = 15
private const val MAX_POINTS = 4
private const val BRAND_COLOR = 0xFF7D00FF.toInt()
private const val COLOR_POSTED = 0xFF2E9E5B.toInt()
private const val COLOR_FAILED = 0xFFD93025.toInt()
