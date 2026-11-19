package com.example.screencast.controller

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
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
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Quick Settings tile that starts and stops the Shizuku-backed capture server.
 *
 * Version matrix:
 *  - Android 7.0 (API 24): [TileService] exists. The tile has to be added by
 *    the user from the QS edit screen.
 *  - Android 10 (API 29): [Tile.setSubtitle] becomes available.
 *  - Android 11 (API 30): content/state descriptions become available.
 *  - Android 13 (API 33): the app may ask the system to add the tile through
 *    [StatusBarManager.requestAddTileService]; see [requestAddTile].
 *  - Android 14 (API 34): understands the TOGGLEABLE_TILE meta-data declared in
 *    the manifest. Taps that need the UI use a plain [startActivity] because
 *    `startActivityAndCollapse` is unreliable once the panel starts closing.
 *
 * Threading: every [TileService] callback arrives on the main thread, but each
 * Shizuku call is a binder round-trip. [onClick] therefore only flips an atomic
 * gate and hands the real work to [workerScope] on [Dispatchers.IO]; tile and
 * Toast updates are posted back to the main looper. The worker scope belongs to
 * the process rather than to this service instance: the system unbinds the tile
 * once the panel collapses, and cancelling the work with the service would
 * abort a start/stop halfway through.
 *
 * Long press: [TileService] has no long-press callback. The framework itself
 * launches the activity that declares the `QS_TILE_PREFERENCES` intent filter
 * (see AndroidManifest.xml on [MainActivity]).
 */
class ScreenCastTileService : TileService() {
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var stateStore: CastStateStore
    private lateinit var serverLauncher: ServerLauncher

    /** False once the system has unbound the service; guards qsTile access. */
    @Volatile
    private var attached = false

    /** Prevents overlapping start/stop work from repeated taps. */
    private val actionInFlight = AtomicBoolean(false)

    /**
     * True while the cached state still has to be verified against the control
     * port. Rendering a stale `RUNNING` from the cache is what made the tile
     * claim "运行中" after the app process had been killed.
     */
    @Volatile
    private var verifying = false

    /** Re-probe while the panel is open, so a desktop connect/disconnect shows. */
    private var pollJob: Job? = null

    private val stateListener = CastStateStore.Listener {
        // CastStateStore already posts listener callbacks on the main looper.
        renderTile()
    }

    override fun onCreate() {
        super.onCreate()
        attached = true
        stateStore = CastStateStore.getInstance(this)
        serverLauncher = ServerLauncher.getInstance(this)
        stateStore.addListener(stateListener)
        renderTile()
    }

    override fun onStartListening() {
        super.onStartListening()
        // Reconcile with the control port instead of trusting the persisted
        // state: after the app process is killed the cache can still claim
        // RUNNING. Until the probe answers, show a neutral "checking" label
        // rather than a wrong "运行中".
        if (stateStore.getState() == CastStateStore.State.RUNNING) {
            verifying = true
        }
        Log.i(TAG, "onStartListening state=${stateStore.getState()}")
        renderTile()
        refreshFromSource()
        startPolling()
    }

    override fun onStopListening() {
        super.onStopListening()
        pollJob?.cancel()
        pollJob = null
    }

    /**
     * Keeps the tile current while the panel is open: a desktop connection can
     * start/stop the server without the app being involved at all.
     */
    private fun startPolling() {
        pollJob?.cancel()
        pollJob = workerScope.launch {
            while (isActive) {
                delay(POLL_INTERVAL_MS)
                reconcileFromProbe()
            }
        }
    }

    override fun onTileAdded() {
        super.onTileAdded()
        renderTile()
        refreshFromSource()
    }

    override fun onClick() {
        if (!actionInFlight.compareAndSet(false, true)) {
            // A toggle is already running; ignore the extra tap instead of
            // queueing a second start/stop behind it.
            Log.i(TAG, "onClick ignored: an action is already running")
            return
        }
        workerScope.launch {
            try {
                // The tile is a pure start/stop control for the capture
                // service. Shizuku state is the controller app's business: if it
                // is unavailable the service start fails on its own and the tile
                // simply keeps its previous appearance.
                val serving = ServerProbe.isListening()
                Log.i(
                    TAG,
                    "toggle: serving=$serving cached=${stateStore.getState()}"
                )
                if (serving) {
                    stopCapture()
                } else {
                    startCapture()
                }
            } catch (error: Throwable) {
                Log.e(TAG, "toggle failed", error)
                withContext(Dispatchers.Main) {
                    toast(
                        getString(
                            R.string.server_action_failed,
                            error.message ?: error.javaClass.simpleName
                        )
                    )
                }
            } finally {
                actionInFlight.set(false)
                scheduleTileUpdate()
            }
        }
    }

    /** Starts the capture server; the foreground service is preferred. */
    private suspend fun startCapture() {
        // Do not write STOPPED here just to "repair" the cache: the probe above
        // already established that nothing is listening, and an extra
        // STOPPED paint makes the tile visibly flash 停止 -> 启动中 -> 运行中.
        val serviceHandled = ScreenCastForegroundService.start(this@ScreenCastTileService)
        if (!serviceHandled) {
            // Android 12+ can refuse a foreground-service start that originates
            // from the Quick Settings panel. The plain launcher then keeps the
            // session working, just without the foreground-service lifetime
            // guarantee.
            try {
                withTimeoutOrNull(START_TIMEOUT_MS) { serverLauncher.start() }
            } catch (error: Throwable) {
                Log.e(TAG, "launcher start failed", error)
                stateStore.setState(CastStateStore.State.ERROR)
                withContext(Dispatchers.Main) {
                    toast(
                        getString(
                            R.string.server_action_failed,
                            error.message ?: error.javaClass.simpleName
                        )
                    )
                }
                return
            }
        }
        // One-tap casting: announce right away so a desktop host with
        // auto-connect enabled joins within its connect-retry window. Harmless
        // when no host listens.
        DiscoveryBroadcaster.announce(pskRequired = false)
        Log.i(TAG, "start requested (foregroundService=$serviceHandled)")
    }

    /** Stops the capture server and tears down the foreground service. */
    private suspend fun stopCapture() {
        stateStore.setState(CastStateStore.State.STOPPING)
        // The launcher is stopped first so the server dies even when its
        // Shizuku handle was lost with a previous app process (`pkill` by class
        // name still works).
        try {
            withTimeoutOrNull(STOP_TIMEOUT_MS) { serverLauncher.stop() }
        } catch (error: Throwable) {
            // `pkill` itself can fail (process already gone, shell hiccup) even
            // though the server is dead. The port decides below, not this call.
            Log.w(TAG, "launcher stop failed: ${error.message}")
        }

        // Ground truth: a failed Shizuku call must not leave the tile showing
        // "异常" for a server that is actually gone, and a silently surviving
        // server must not be reported as stopped.
        if (awaitNotServing()) {
            Log.i(TAG, "stop completed")
            // A background app may not startService() the FGS (Android 12+
            // throws BackgroundServiceStartNotAllowed), so the teardown goes
            // through stopService(), which triggers the same onDestroy cleanup.
            ScreenCastForegroundService.stopServiceOnly(this@ScreenCastTileService)
            stateStore.setState(CastStateStore.State.STOPPED)
        } else {
            Log.w(TAG, "control port is still open after stop")
            // A normal app cannot kill the shell process; keep the tile honest
            // and tell the user what to do instead of showing 异常/已停止.
            stateStore.setState(CastStateStore.State.SHIZUKU_LOST)
            withContext(Dispatchers.Main) {
                toast(getString(R.string.shizuku_lost_cannot_stop))
            }
        }
    }

    /** True once nothing listens on the control port, waiting up to ~2.5 s. */
    private suspend fun awaitNotServing(): Boolean {
        repeat(STOP_VERIFY_ATTEMPTS) { attempt ->
            if (!ServerProbe.isListening()) {
                return true
            }
            if (attempt < STOP_VERIFY_ATTEMPTS - 1) {
                delay(STOP_VERIFY_DELAY_MS)
            }
        }
        return !ServerProbe.isListening()
    }

    override fun onDestroy() {
        attached = false
        pollJob?.cancel()
        pollJob = null
        stateStore.removeListener(stateListener)
        super.onDestroy()
    }

    /**
     * Repairs a cached state that no longer matches reality.
     *
     * The tile never inspects Shizuku: whether the controller app can control
     * the server is the app's concern, and the shared state store already
     * carries [CastStateStore.State.SHIZUKU_LOST] when that happens.
     */
    private fun refreshFromSource() {
        workerScope.launch { reconcileFromProbe() }
    }

    /**
     * Makes the state follow the control port in both directions.
     *
     * A session can be started by the desktop (wireless ADB) or by the app in a
     * process the tile never talked to; without the upward repair the tile kept
     * saying "已停止" while the PC was already casting.
     */
    private suspend fun reconcileFromProbe() {
        val listening = ServerProbe.isListening()
        val state = stateStore.getState()
        val target = when {
            !listening &&
                (state == CastStateStore.State.RUNNING ||
                    state == CastStateStore.State.SHIZUKU_LOST ||
                    state == CastStateStore.State.STARTING) ->
                CastStateStore.State.STOPPED
            listening &&
                (state == CastStateStore.State.STOPPED ||
                    state == CastStateStore.State.ERROR ||
                    state == CastStateStore.State.UNAUTHORIZED) ->
                CastStateStore.State.RUNNING
            else -> state
        }
        if (target != state) {
            Log.i(TAG, "probe reconcile: $state -> $target (listening=$listening)")
            stateStore.setState(target)
        }
        verifying = false
        scheduleTileUpdate()
    }

    /** Repaints the tile on the main looper, from any thread. */
    private fun scheduleTileUpdate() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            renderTile()
        } else {
            mainHandler.post { renderTile() }
        }
    }

    private fun renderTile() {
        if (!attached) {
            return
        }
        val tile = try {
            qsTile
        } catch (_: Throwable) {
            null
        } ?: return

        val visual = visualFor(stateStore.getState(), verifying)
        runCatching {
            tile.state = visual.tileState
            tile.icon = Icon.createWithResource(this, visual.iconRes)
            tile.label = getString(visual.labelRes)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                tile.subtitle = getString(visual.subtitleRes)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                tile.contentDescription = getString(visual.labelRes)
                tile.stateDescription = getString(visual.subtitleRes)
            }
            tile.updateTile()
        }
    }

    /**
     * Maps the capture service state to what the user sees.
     *
     * The tile mirrors the app: no Shizuku-dependent labels. A lost Shizuku is
     * rendered as "运行中" with an explanatory subtitle because the session is
     * still serving.
     */
    private fun visualFor(
        state: CastStateStore.State,
        verifying: Boolean = false
    ): TileVisual {
        return when {
            verifying && (state == CastStateStore.State.RUNNING ||
                state == CastStateStore.State.SHIZUKU_LOST) -> TileVisual(
                tileState = Tile.STATE_INACTIVE,
                iconRes = R.drawable.ic_tile,
                labelRes = R.string.tile_label_checking,
                subtitleRes = R.string.tile_subtitle_checking
            )
            state == CastStateStore.State.RUNNING -> TileVisual(
                tileState = Tile.STATE_ACTIVE,
                iconRes = R.drawable.ic_tile_running,
                labelRes = R.string.tile_label_running,
                subtitleRes = R.string.tile_subtitle_stop
            )
            state == CastStateStore.State.SHIZUKU_LOST -> TileVisual(
                tileState = Tile.STATE_ACTIVE,
                iconRes = R.drawable.ic_tile_running,
                labelRes = R.string.tile_label_running,
                subtitleRes = R.string.tile_subtitle_shizuku_lost
            )
            state == CastStateStore.State.STARTING -> TileVisual(
                tileState = Tile.STATE_ACTIVE,
                iconRes = R.drawable.ic_tile_running,
                labelRes = R.string.tile_label_starting,
                subtitleRes = R.string.tile_subtitle_busy
            )
            state == CastStateStore.State.STOPPING -> TileVisual(
                tileState = Tile.STATE_INACTIVE,
                iconRes = R.drawable.ic_tile,
                labelRes = R.string.tile_label_stopping,
                subtitleRes = R.string.tile_subtitle_busy
            )
            state == CastStateStore.State.ERROR -> TileVisual(
                tileState = Tile.STATE_INACTIVE,
                iconRes = R.drawable.ic_tile_unauthorized,
                labelRes = R.string.tile_label_error,
                subtitleRes = R.string.tile_subtitle_start
            )
            else -> TileVisual(
                tileState = Tile.STATE_INACTIVE,
                iconRes = R.drawable.ic_tile,
                labelRes = R.string.tile_label_stopped,
                subtitleRes = R.string.tile_subtitle_start
            )
        }
    }

    /**
     * Repaints the tile. Shizuku never appears here: the tile only mirrors the
     * capture service's state, so it matches the app in every case.
     */

    private fun toast(message: String) {
        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
    }

    private class TileVisual(
        val tileState: Int,
        val iconRes: Int,
        val labelRes: Int,
        val subtitleRes: Int
    )

    companion object {
        private const val TAG = "ScreenCastTile"

        /** Upper bounds so a hung Shizuku call can never freeze the tile. */
        private const val START_TIMEOUT_MS = 35_000L
        private const val STOP_TIMEOUT_MS = 15_000L

        /** How long the stop path waits for the control port to close. */
        private const val STOP_VERIFY_ATTEMPTS = 6
        private const val STOP_VERIFY_DELAY_MS = 400L

        /** Refresh cadence while the Quick Settings panel is open. */
        private const val POLL_INTERVAL_MS = 2_000L

        /**
         * Process-wide worker: a start/stop must survive [onDestroy] because
         * the system unbinds the tile service as soon as the panel collapses.
         */
        private val workerScope =
            CoroutineScope(SupervisorJob() + Dispatchers.IO)

        fun tileComponent(context: Context): ComponentName {
            return ComponentName(context, ScreenCastTileService::class.java)
        }

        /**
         * Asks the system to add this tile. Returns false on Android 7.0-12,
         * where [StatusBarManager.requestAddTileService] does not exist and the
         * user has to add the tile from the QS edit screen by hand.
         *
         * Must be called while the app is in the foreground; the system shows
         * the confirmation dialog and reports the outcome through [onResult].
         */
        fun requestAddTile(context: Context, onResult: ((Int) -> Unit)? = null): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                return false
            }
            val manager = context.getSystemService(StatusBarManager::class.java)
                ?: return false
            val executor: Executor = context.mainExecutor
            val callback = java.util.function.Consumer<Int> { result ->
                onResult?.invoke(result)
                // Bind the tile right away so it shows the real state instead
                // of waiting for the user to open the panel.
                requestListeningState(context, tileComponent(context))
            }
            manager.requestAddTileService(
                tileComponent(context),
                context.getString(R.string.tile_label),
                Icon.createWithResource(context, R.drawable.ic_tile),
                executor,
                callback
            )
            return true
        }
    }
}
