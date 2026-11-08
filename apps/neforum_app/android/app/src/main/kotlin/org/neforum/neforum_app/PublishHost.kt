package org.neforum.neforum_app

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** One network of a run, as Dart's `begin` names it. */
class PublishNetwork(val id: String, val name: String, val bytes: Long)

/**
 * "neforum/publish_host" (lib/platform/publish_host.dart), process-wide: it outlives
 * any Activity. While a run is on record the engine stays when the Activity goes, so
 * the run goes on where it already runs, in the main isolate, and [PublishService]
 * keeps the process alive around it. Reopening NEFORUM attaches to the same engine.
 *
 * With no run this does nothing at all: the Activity makes and destroys its engine
 * as before. Main thread only.
 */
object PublishHost {
    private const val TAG = "PublishHost"
    private const val CHANNEL = "neforum/publish_host"

    /** Android's notification rate is not the reason: nobody reads faster than this. */
    private const val UPDATE_INTERVAL_MS = 2_000L

    /** startForeground must follow within seconds, or Android ends the process. */
    private const val START_WATCHDOG_MS = 5_000L

    private val main = Handler(Looper.getMainLooper())

    /** The posts in progress, oldest first, each with its networks. */
    private val runs = LinkedHashMap<String, List<PublishNetwork>>()
    private val waitingForStart = mutableListOf<MethodChannel.Result>()
    private var starting = false

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var activityAttached = false
    private var appContext: Context? = null

    /** The last snapshot from Dart, and when the notification last showed one. */
    private var latest: Map<*, *>? = null
    private var lastPostedAt = 0L
    private var postPending = false
    private val poster = Runnable {
        postPending = false
        postNow()
    }

    val runActive: Boolean get() = runs.isNotEmpty()

    /** The person swiped the notification away: it stays away (Android 14+ lets them). */
    var dismissed = false

    /** The engine for a new Activity to attach to, when a run kept one. */
    fun retainedEngine(): FlutterEngine? = if (activityAttached) null else engine

    /** Whether the engine outlives its Activity right now. */
    fun retains(candidate: FlutterEngine?): Boolean = candidate != null && candidate === engine && runActive

    /** Whether this engine already ran through [attach], so its channels exist. */
    fun isKnown(candidate: FlutterEngine): Boolean = candidate === engine

    fun attach(context: Context, flutterEngine: FlutterEngine) {
        appContext = context.applicationContext
        if (flutterEngine === engine) {
            activityAttached = true
            return
        }
        // A second window while a run goes on has an engine of its own, as before.
        if (engine != null && runActive) return
        engine = flutterEngine
        activityAttached = true
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result -> handle(call, result) }
        }
    }

    /** The Activity lets go of [flutterEngine]; if a run keeps it, Dart hears why. */
    fun detach(flutterEngine: FlutterEngine) {
        if (flutterEngine !== engine) return
        activityAttached = false
        if (runActive) {
            channel?.invokeMethod("windowClosing", null)
        } else {
            // The delegate destroys it right after this.
            forgetEngine()
        }
    }

    private fun forgetEngine() {
        channel?.setMethodCallHandler(null)
        channel = null
        engine = null
        latest = null
        dismissed = false
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "begin" -> begin(call, result)
            "update" -> {
                val snapshot = call.arguments as? Map<*, *>
                if (snapshot != null && runActive && isShown(snapshot)) update(snapshot)
                result.success(null)
            }
            "end" -> {
                end(call.argument<String>("postId") ?: "")
                result.success(null)
            }
            "lastExitReason" -> result.success(lastExitReason())
            else -> result.notImplemented()
        }
    }

    private fun begin(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        val postId = call.argument<String>("postId")
        if (context == null || postId.isNullOrEmpty()) {
            result.success(false)
            return
        }
        val networks = (call.argument<List<Map<String, Any?>>>("networks") ?: emptyList()).map {
            PublishNetwork(it["id"] as? String ?: "", it["name"] as? String ?: "", (it["bytes"] as? Number)?.toLong() ?: 0L)
        }
        // A second begin brings the plan's networks; the bar's parts are made from them.
        if (networks.isNotEmpty() || !runs.containsKey(postId)) runs[postId] = networks
        if (PublishService.isForeground) {
            postNow()
            result.success(true)
            return
        }
        waitingForStart.add(result)
        if (starting) return
        starting = true
        dismissed = false
        try {
            // From a visible app only. In the background on Android 12+ this throws
            // ForegroundServiceStartNotAllowedException, an IllegalStateException.
            ContextCompat.startForegroundService(context, Intent(context, PublishService::class.java))
            main.postDelayed(startWatchdog, START_WATCHDOG_MS)
        } catch (e: Exception) {
            Log.w(TAG, "Android refused the service: ${e.javaClass.simpleName}")
            serviceStarted(false)
        }
    }

    private val startWatchdog = Runnable { serviceStarted(false) }

    /** From [PublishService]: whether it reached the foreground. Answers Dart's begin. */
    fun serviceStarted(ok: Boolean) {
        main.removeCallbacks(startWatchdog)
        starting = false
        val waiting = waitingForStart.toList()
        waitingForStart.clear()
        waiting.forEach { it.success(ok) }
    }

    /**
     * Dart sends one snapshot per run, each with its postId (iOS gives each run its
     * own Live Activity). The one notification shows the oldest run; its headline
     * already counts the others.
     */
    private fun isShown(snapshot: Map<*, *>): Boolean {
        val postId = snapshot["postId"] as? String ?: return true
        return postId == firstPost()
    }

    private fun update(snapshot: Map<*, *>) {
        latest = snapshot
        val wait = lastPostedAt + UPDATE_INTERVAL_MS - SystemClock.elapsedRealtime()
        if (wait <= 0) {
            postNow()
        } else if (!postPending) {
            postPending = true
            main.postDelayed(poster, wait)
        }
    }

    private fun postNow() {
        lastPostedAt = SystemClock.elapsedRealtime()
        PublishService.show()
    }

    private fun end(postId: String) {
        runs.remove(postId)
        if (runActive) return
        main.removeCallbacks(poster)
        postPending = false
        latest = null
        PublishService.finish()
        // Nothing attached, nothing running: the next launch is a clean cold start.
        if (!activityAttached) {
            val done = engine
            // After this message's reply is on its way.
            main.post {
                if (!runActive && !activityAttached && engine === done) {
                    forgetEngine()
                    done?.destroy()
                }
            }
        }
    }

    /** What the notification shows now. Null fields before Dart's first snapshot. */
    fun snapshot(): Map<*, *>? = latest

    /** The bar's parts: the oldest run's networks. */
    fun networks(): List<PublishNetwork> = runs.values.firstOrNull() ?: emptyList()

    fun firstPost(): String? = runs.keys.firstOrNull()

    /** The Cancel action on the notification: it stands for every run it counts. */
    fun cancelAll() {
        runs.keys.toList().forEach { channel?.invokeMethod("cancelRequested", mapOf("postId" to it)) }
    }

    /** The service's time is up; it stops right after this. Dart cancels its runs. */
    fun timedOut() {
        channel?.invokeMethod("timedOut", null)
    }

    fun openPost(postId: String) {
        channel?.invokeMethod("openPost", mapOf("postId" to postId))
    }

    private fun lastExitReason(): Int? {
        val context = appContext ?: return null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        return try {
            val manager = context.getSystemService(ActivityManager::class.java)
            manager.getHistoricalProcessExitReasons(context.packageName, 0, 1).firstOrNull()?.reason
        } catch (e: Exception) {
            null
        }
    }
}
