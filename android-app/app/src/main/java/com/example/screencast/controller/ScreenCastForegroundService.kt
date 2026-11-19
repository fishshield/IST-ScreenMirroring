package com.example.screencast.controller

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Foreground wrapper around [ServerLauncher].
 *
 * The Shizuku `newProcess` handle and the capture `app_process` live only as
 * long as the app process does, so the controller was easy to lose once
 * Android reclaimed a backgrounded Activity. This service owns that lifetime:
 * it starts the server, keeps a low-importance ongoing notification with a
 * "stop" action, and stops the server in [onDestroy].
 *
 * [ServerLauncher] itself is intentionally untouched: no command line, jar
 * path, timeout or start/stop semantics changed here. This class only maps the
 * launcher's outcome onto [CastStateStore] and the notification.
 *
 * Service type: `specialUse` (declared in AndroidManifest.xml with a
 * `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` reason). None of the predefined types fit:
 * capture is done by a user-authorized Shizuku shell process, not by
 * MediaProjection, and the service mirrors the screen to a desktop host.
 */
class ScreenCastForegroundService : Service() {
    private lateinit var stateStore: CastStateStore

    /**
     * Created lazily and only for start/stop. The service deliberately keeps no
     * standing Shizuku reference: once the capture server is running, a Shizuku
     * restart must not take the foreground protection (and with it the capture
     * process) down.
     */
    private var serverLauncher: ServerLauncher? = null

    private fun launcher(): ServerLauncher {
        return serverLauncher
            ?: ServerLauncher.getInstance(this).also { serverLauncher = it }
    }

    /**
     * Process-wide, not service-scoped: [onDestroy] may run while the stop
     * request is still in flight, and a service-scoped coroutine would be
     * cancelled exactly then.
     */
    private val workerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private var startRequested = false
    private var startFailed = false
    private var stopRequested = false
    private var foregroundStarted = false

    /** Polls the capture process while this service owns it. */
    private var watchdog: Job? = null

    /** True once the watchdog saw the capture process disappear. */
    private var serverGone = false

    /** Prevents onDestroy from retrying a stop that Shizuku cannot perform. */
    private var stopFailedDueToShizuku = false

    private val stateListener = CastStateStore.Listener { state ->
        // CastStateStore posts listener callbacks on the main looper.
        updateNotification(state)
    }

    override fun onCreate() {
        super.onCreate()
        stateStore = CastStateStore.getInstance(this)
        stateStore.addListener(stateListener)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                if (startFailed || serverGone) {
                    // A previous start already failed (or the process died): the
                    // stop path below would return early and leave this service
                    // (and its ongoing notification) alive forever. Tear it
                    // down directly.
                    stopForegroundCompat()
                    stopSelf()
                } else {
                    requestServerStop(keepAliveOnFailure = foregroundStarted)
                }
                return START_NOT_STICKY
            }
            else -> {
                if (intent == null && !startRequested) {
                    // START_STICKY restart after the process was killed. Do not
                    // silently start a second capture server: the shell process
                    // may still be running, and a second bind would fail. Report
                    // the truth and let the tile/activity request a start.
                    Log.w(TAG, "sticky restart without a start request; not starting capture")
                    stopForegroundCompat()
                    stopSelf()
                    return START_NOT_STICKY
                }
                // A null intent means the system recreated the service after the
                // process was killed; treat it as a fresh start request.
                val initial = if (foregroundStarted) {
                    stateStore.getState()
                } else {
                    CastStateStore.State.STARTING
                }
                startForegroundCompat(buildNotification(initial))
                if (!startRequested) {
                    startRequested = true
                    workerScope.launch { startServer() }
                }
                return START_STICKY
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        watchdog?.cancel()
        watchdog = null
        stateStore.removeListener(stateListener)
        // Guarded: a normal ACTION_STOP already stopped the server and only
        // then called stopSelf(). Skip the retry when Shizuku is known to be
        // unable to stop it, otherwise stopSelf() would loop.
        if (!stopFailedDueToShizuku) {
            requestServerStop(fromDestroy = true)
        }
        super.onDestroy()
    }

    private suspend fun startServer() {
        try {
            // Reflect "service is starting" before the launcher's own state
            // changes, so the UI and the notification react immediately.
            stateStore.setState(CastStateStore.State.STARTING)
            if (ServerProbe.isListening()) {
                // Adopt a server that is already serving (started from ADB or
                // by a previous process). This path never touches Shizuku, so
                // the foreground service can protect an existing session even
                // when Shizuku is gone.
                Log.i(TAG, "adopting an already-running capture server")
                stateStore.setState(
                    if (runCatching { rikka.shizuku.Shizuku.pingBinder() }
                            .getOrDefault(false)
                    ) {
                        CastStateStore.State.RUNNING
                    } else {
                        CastStateStore.State.SHIZUKU_LOST
                    }
                )
            } else {
                launcher().start()
                stateStore.setState(CastStateStore.State.RUNNING)
            }
            // Tell desktop hosts on the LAN that this phone now serves a
            // session. ServerLauncher runs the capture server without
            // --psk-hex, so the advertised pskRequired is false.
            DiscoveryBroadcaster.announce(pskRequired = false)
            startWatchdog()
            Log.i(TAG, "Capture server is running under the foreground service")
        } catch (error: Throwable) {
            Log.e(TAG, "Capture server failed to start", error)
            startFailed = true
            stateStore.setState(CastStateStore.State.ERROR)
            withContext(Dispatchers.Main) { stopSelf() }
        }
    }

    /**
     * Watches the capture process for as long as this service owns it.
     *
     * If `app_process` disappears without going through [requestServerStop]
     * (Shizuku restarted, external `pkill`, OOM kill), the persisted state
     * would otherwise stay RUNNING forever: the Quick Settings tile would keep
     * advertising “投屏 · 运行中” and its next tap would take the stop branch,
     * which looks like an inverted toggle to the user.
     */
    private fun startWatchdog() {
        watchdog?.cancel()
        watchdog = workerScope.launch {
            while (isActive) {
                delay(WATCHDOG_INTERVAL_MS)
                // Liveness is the control port, not Shizuku: the capture server
                // is an independent shell process and keeps streaming when the
                // Shizuku binder dies. Only a closed port means the session is
                // over.
                if (!ServerProbe.isListening()) {
                    Log.w(TAG, "capture server stopped listening; marking STOPPED")
                    serverGone = true
                    stateStore.setState(CastStateStore.State.STOPPED)
                    withContext(Dispatchers.Main) {
                        stopForegroundCompat()
                        stopSelf()
                    }
                    return@launch
                }
            }
        }
    }

    private fun requestServerStop(
        fromDestroy: Boolean = false,
        keepAliveOnFailure: Boolean = foregroundStarted
    ) {
        watchdog?.cancel()
        watchdog = null
        // Nothing to stop: either a stop is already in flight, the start failed
        // and never produced a process, or the process died on its own (the
        // watchdog already published STOPPED and the service is stopping itself).
        if (stopRequested || startFailed || serverGone) {
            return
        }
        // Nothing is listening: the stop is already done. Without this check the
        // onDestroy path would ask the launcher to stop a dead server and flip a
        // successful STOPPED into SHIZUKU_LOST.
        if (!ServerProbe.isListeningBlocking()) {
            serverGone = true
            stateStore.setState(CastStateStore.State.STOPPED)
            if (!fromDestroy) {
                stopForegroundCompat()
                stopSelf()
            }
            return
        }
        stopRequested = true
        workerScope.launch {
            val stopped = try {
                launcher().stop()
            } catch (error: Throwable) {
                Log.e(TAG, "Capture server failed to stop cleanly", error)
                false
            }
            val stillServing = ServerProbe.isListening()
            withContext(Dispatchers.Main) {
                if (!stopped && stillServing) {
                    // Shizuku is gone and a normal app cannot kill the shell
                    // process. Keep the foreground service (and its protection)
                    // alive and tell the user what happened.
                    stopRequested = false
                    stopFailedDueToShizuku = true
                    stateStore.setState(CastStateStore.State.SHIZUKU_LOST)
                    if (!fromDestroy) {
                        Toast.makeText(
                            this@ScreenCastForegroundService,
                            R.string.shizuku_lost_cannot_stop,
                            Toast.LENGTH_LONG
                        ).show()
                    }
                    if (!keepAliveOnFailure) {
                        // Nothing was foreground-protected here (the stop came
                        // from a non-running service); do not linger as a plain
                        // started service.
                        stopForegroundCompat()
                        stopSelf()
                    }
                } else {
                    stopForegroundCompat()
                    stopSelf()
                }
            }
        }
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.fgs_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.fgs_channel_desc)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(state: CastStateStore.State): Notification {
        val stopIntent = PendingIntent.getService(
            this,
            REQUEST_STOP,
            Intent(this, ScreenCastForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val openIntent = PendingIntent.getActivity(
            this,
            REQUEST_OPEN,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopAction = Notification.Action.Builder(
            Icon.createWithResource(this, R.drawable.ic_stop),
            getString(R.string.fgs_stop_action),
            stopIntent
        ).build()
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile)
            .setContentTitle(getString(R.string.fgs_title))
            .setContentText(notificationText(state))
            .setContentIntent(openIntent)
            .setCategory(Notification.CATEGORY_SERVICE)
            // Non-dismissible while running. Android 14 lets the user swipe away
            // foreground-service notifications regardless; the service and the
            // capture session keep running in that case.
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(stopAction)
            .build()
    }

    private fun notificationText(state: CastStateStore.State): String {
        return when (state) {
            CastStateStore.State.STARTING -> getString(R.string.fgs_text_starting)
            CastStateStore.State.RUNNING -> getString(R.string.fgs_text_running)
            CastStateStore.State.STOPPING -> getString(R.string.fgs_text_stopping)
            CastStateStore.State.ERROR -> getString(R.string.fgs_text_error)
            CastStateStore.State.UNAUTHORIZED -> getString(R.string.fgs_text_unauthorized)
            CastStateStore.State.STOPPED -> getString(R.string.fgs_text_stopped)
            CastStateStore.State.SHIZUKU_LOST ->
                getString(R.string.fgs_text_shizuku_lost)
        }
    }

    private fun updateNotification(state: CastStateStore.State) {
        if (!foregroundStarted) {
            return
        }
        runCatching {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, buildNotification(state))
        }
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        foregroundStarted = true
    }

    private fun stopForegroundCompat() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        foregroundStarted = false
    }

    companion object {
        private const val TAG = "ScreenCastFgs"
        private const val CHANNEL_ID = "screencast_capture_service"
        private const val NOTIFICATION_ID = 0x5C02
        private const val REQUEST_STOP = 0x5C03
        private const val REQUEST_OPEN = 0x5C04
        private const val WATCHDOG_INTERVAL_MS = 2_000L

        const val ACTION_START = "com.example.screencast.controller.action.START"
        const val ACTION_STOP = "com.example.screencast.controller.action.STOP"

        /**
         * Starts the capture through the foreground service. Returns false when
         * the platform refuses a background `startForegroundService`, which can
         * happen when the request comes from the Quick Settings tile; callers
         * then fall back to the plain launcher path.
         */
        fun start(context: Context): Boolean {
            val intent = Intent(context, ScreenCastForegroundService::class.java)
                .setAction(ACTION_START)
            return try {
                context.startForegroundService(intent)
                true
            } catch (error: Throwable) {
                Log.w(TAG, "startForegroundService refused", error)
                false
            }
        }

        /**
         * Stops the service and, through [onDestroy], the capture server.
         * `startService` is used so the service can report "stopping"; from the
         * background it is refused on Android 8+, and [stopService] then takes
         * over (its onDestroy performs the same stop).
         *
         * Returns true when the stop was delivered to a service instance. A
         * false result means no service was alive, so the caller may still need
         * to stop a server that was started through the launcher fallback.
         */
        fun stop(context: Context): Boolean {
            val intent = Intent(context, ScreenCastForegroundService::class.java)
                .setAction(ACTION_STOP)
            return try {
                context.startService(intent)
                true
            } catch (error: Throwable) {
                Log.w(TAG, "startService refused for stop, using stopService", error)
                context.stopService(Intent(context, ScreenCastForegroundService::class.java))
            }
        }

        /**
         * Tears the service down without starting it. Safe from the background,
         * where `startService` is refused (BackgroundServiceStartNotAllowed on
         * Android 12+); the notification and the watchdog go away through
         * [onDestroy].
         */
        fun stopServiceOnly(context: Context) {
            runCatching {
                context.stopService(
                    Intent(context, ScreenCastForegroundService::class.java)
                )
            }
        }
    }
}
