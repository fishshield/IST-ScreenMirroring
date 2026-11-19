package com.example.screencast.controller

import android.Manifest
import android.app.Activity
import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import kotlinx.coroutines.runBlocking
import rikka.shizuku.Shizuku

/**
 * Shizuku permission UI and capture-server controls.
 *
 * All Shizuku calls are guarded by binder presence and permission checks. The
 * actual shell work is asynchronous in [ServerLauncher]; this Activity never
 * blocks the main thread waiting for a shell result.
 */
class MainActivity : Activity() {
    private lateinit var stateStore: CastStateStore
    private lateinit var statusView: TextView
    private lateinit var encoderFpsView: TextView
    private lateinit var guideView: TextView
    private lateinit var requestPermissionButton: Button
    private lateinit var openShizukuButton: Button
    private lateinit var startButton: Button
    private lateinit var stopButton: Button
    private lateinit var addTileButton: Button

    private var permissionRequested = false

    private val fpsHandler = Handler(Looper.getMainLooper())

    /**
     * Polls the server log for the encoder rate while the Activity is resumed.
     * Runs off the main thread (Shizuku + file read) and only touches the UI on
     * the main looper.
     */
    private val fpsPoll = object : Runnable {
        override fun run() {
            refreshEncoderFps()
            // Also follow the control port: a desktop connection may have
            // started or stopped the session without this app being involved.
            reconcileServerState()
            fpsHandler.postDelayed(this, ENCODER_FPS_POLL_MS)
        }
    }

    private val stateListener = CastStateStore.Listener { state ->
        renderState(state)
    }

    private val binderReceivedListener = Shizuku.OnBinderReceivedListener {
        permissionRequested = false
        refreshShizukuState()
    }

    private val binderDeadListener = Shizuku.OnBinderDeadListener {
        permissionRequested = false
        refreshShizukuState()
    }

    private val permissionResultListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode != REQUEST_CODE) {
                return@OnRequestPermissionResultListener
            }
            if (grantResult == PackageManager.PERMISSION_GRANTED) {
                permissionRequested = false
                stateStore.setState(CastStateStore.State.STOPPED)
                guideView.text = getString(R.string.shizuku_permission_granted)
            } else {
                permissionRequested = true
                stateStore.setState(CastStateStore.State.UNAUTHORIZED)
                guideView.text = getString(R.string.shizuku_permission_denied)
            }
            renderState(stateStore.getState())
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        stateStore = CastStateStore.getInstance(this)
        // Only for its side effects: clearing a stale RUNNING state left over
        // from a previous app process and registering the binder-death
        // listener. Start/stop now goes through the foreground service.
        ServerLauncher.getInstance(this)
        stateStore.addListener(stateListener)
        setContentView(buildContentView())

        Shizuku.addBinderReceivedListenerSticky(binderReceivedListener)
        Shizuku.addBinderDeadListener(binderDeadListener)
        Shizuku.addRequestPermissionResultListener(permissionResultListener)

        refreshShizukuState()
    }

    override fun onResume() {
        super.onResume()
        refreshShizukuState()
        reconcileServerState()
        fpsHandler.removeCallbacks(fpsPoll)
        fpsHandler.post(fpsPoll)
    }

    override fun onPause() {
        fpsHandler.removeCallbacks(fpsPoll)
        super.onPause()
    }

    override fun onDestroy() {
        stateStore.removeListener(stateListener)
        Shizuku.removeBinderReceivedListener(binderReceivedListener)
        Shizuku.removeBinderDeadListener(binderDeadListener)
        Shizuku.removeRequestPermissionResultListener(permissionResultListener)
        super.onDestroy()
    }

    /**
     * Repairs a state that claims RUNNING after the capture process died
     * (Shizuku restart, `pkill`, OOM). Without this the Activity — and the
     * Quick Settings tile — would keep showing “运行中” for a server that no
     * longer exists, so the next tap would try to stop nothing.
     */
    private fun reconcileServerState() {
        val state = stateStore.getState()
        if (state == CastStateStore.State.STARTING ||
            state == CastStateStore.State.STOPPING
        ) {
            return
        }
        Thread {
            val listening = ServerProbe.isListeningBlocking()
            val binderUp = runCatching { Shizuku.pingBinder() }.getOrDefault(false)
            val target = when {
                // The session can be started by the desktop (wireless ADB) or by
                // another process; the port is the truth.
                listening && binderUp -> CastStateStore.State.RUNNING
                listening -> CastStateStore.State.SHIZUKU_LOST
                state == CastStateStore.State.RUNNING ||
                    state == CastStateStore.State.SHIZUKU_LOST ->
                    CastStateStore.State.STOPPED
                else -> state
            }
            if (stateStore.getState() != target) {
                stateStore.setState(target)
            }
        }.start()
    }

    /**
     * Refreshes the “编码帧率” line from the server log.
     *
     * The rate is parsed from `[encoder] target-fps=... actual=...` or the
     * per-second `[encoder] 1s ... frames=N` line, so no control-protocol field
     * is added for it.
     */
    private fun refreshEncoderFps() {
        if (!::encoderFpsView.isInitialized) {
            return
        }
        if (stateStore.getState() != CastStateStore.State.RUNNING) {
            encoderFpsView.text = getString(R.string.main_encoder_fps_idle)
            return
        }
        Thread {
            val launcher = ServerLauncher.getInstance(this@MainActivity)
            val summary = try {
                runBlocking { launcher.readEncoderFpsSummary() }
            } catch (error: Throwable) {
                getString(R.string.main_encoder_fps_idle)
            }
            runOnUiThread {
                if (!isFinishing && ::encoderFpsView.isInitialized) {
                    encoderFpsView.text = summary
                }
            }
        }.start()
    }

    private fun refreshShizukuState() {
        if (!Shizuku.pingBinder()) {
            val current = stateStore.getState()
            // Losing Shizuku does not stop the capture server: a session that is
            // still running only loses *control*. Show that instead of "未授权".
            val stillCasting = current == CastStateStore.State.RUNNING ||
                current == CastStateStore.State.SHIZUKU_LOST ||
                current == CastStateStore.State.STARTING
            val target = if (stillCasting) {
                CastStateStore.State.SHIZUKU_LOST
            } else {
                CastStateStore.State.UNAUTHORIZED
            }
            stateStore.setState(target)
            guideView.text = if (stillCasting) {
                getString(R.string.shizuku_lost_message)
            } else {
                getString(R.string.shizuku_not_running)
            }
            requestPermissionButton.visibility = View.GONE
            openShizukuButton.visibility = View.VISIBLE
            renderState(target)
            return
        }
        if (Shizuku.isPreV11()) {
            stateStore.setState(CastStateStore.State.UNAUTHORIZED)
            guideView.text = getString(R.string.shizuku_pre_v11)
            requestPermissionButton.visibility = View.GONE
            openShizukuButton.visibility = View.GONE
            renderState(CastStateStore.State.UNAUTHORIZED)
            return
        }

        val granted = try {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (error: Throwable) {
            guideView.text = getString(R.string.shizuku_binder_error, error.message ?: "")
            false
        }
        if (granted) {
            permissionRequested = false
            if (stateStore.getState() == CastStateStore.State.UNAUTHORIZED) {
                stateStore.setState(CastStateStore.State.STOPPED)
            }
            guideView.text = getString(R.string.shizuku_available_authorized)
            requestPermissionButton.visibility = View.GONE
            openShizukuButton.visibility = View.GONE
            renderState(stateStore.getState())
            return
        }

        stateStore.setState(CastStateStore.State.UNAUTHORIZED)
        openShizukuButton.visibility = View.GONE
        requestPermissionButton.visibility = View.VISIBLE
        val rationale = try {
            Shizuku.shouldShowRequestPermissionRationale()
        } catch (_: Throwable) {
            false
        }
        if (rationale) {
            guideView.text = getString(R.string.shizuku_permission_denied_guide)
            renderState(CastStateStore.State.UNAUTHORIZED)
            return
        }
        if (!permissionRequested) {
            requestPermission()
        } else {
            guideView.text = getString(R.string.shizuku_waiting_permission)
            renderState(CastStateStore.State.UNAUTHORIZED)
        }
    }

    private fun requestPermission() {
        if (!Shizuku.pingBinder() || Shizuku.isPreV11()) {
            refreshShizukuState()
            return
        }
        permissionRequested = true
        try {
            Shizuku.requestPermission(REQUEST_CODE)
            guideView.text = getString(R.string.shizuku_permission_requested)
        } catch (error: Throwable) {
            permissionRequested = false
            guideView.text = getString(
                R.string.shizuku_permission_request_failed,
                error.message ?: ""
            )
        }
        renderState(stateStore.getState())
    }

    /**
     * Starts the capture through [ScreenCastForegroundService] so the Shizuku
     * `app_process` keeps running after this Activity is backgrounded or
     * reclaimed. The service also posts the ongoing notification.
     */
    private fun startCaptureService() {
        if (!isAuthorized()) {
            refreshShizukuState()
            return
        }
        ensureNotificationPermission()
        if (!ScreenCastForegroundService.start(this)) {
            Toast.makeText(this, R.string.fgs_start_failed, Toast.LENGTH_LONG).show()
        }
    }

    private fun stopCaptureService() {
        ScreenCastForegroundService.stop(this)
    }

    /**
     * Android 13+ needs POST_NOTIFICATIONS for the ongoing notification. A
     * denied request does not block the foreground service itself, so the start
     * still proceeds; the user is told the notification will be hidden.
     */
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATIONS
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) {
            return
        }
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            Toast.makeText(
                this,
                R.string.fgs_notification_denied,
                Toast.LENGTH_LONG
            ).show()
        }
    }

    /**
     * Android 13+ can ask the system to place the tile through
     * [StatusBarManager.requestAddTileService]; older releases only support the
     * manual "edit Quick Settings" flow, so the button explains it instead of
     * failing silently.
     */
    private fun requestAddTile() {
        val requested = try {
            ScreenCastTileService.requestAddTile(this) { result ->
                showAddTileResult(result)
            }
        } catch (error: Throwable) {
            Toast.makeText(
                this,
                getString(
                    R.string.tile_add_error,
                    error.message ?: error.javaClass.simpleName
                ),
                Toast.LENGTH_LONG
            ).show()
            false
        }
        if (!requested) {
            Toast.makeText(
                this,
                R.string.tile_add_unavailable,
                Toast.LENGTH_LONG
            ).show()
        }
    }

    private fun showAddTileResult(result: Int) {
        val message = when (result) {
            StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ->
                R.string.tile_add_success
            StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED ->
                R.string.tile_add_already
            else -> R.string.tile_add_declined
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun isAuthorized(): Boolean {
        return try {
            Shizuku.pingBinder() &&
                !Shizuku.isPreV11() &&
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) {
            false
        }
    }

    private fun renderState(state: CastStateStore.State) {
        if (!::statusView.isInitialized) {
            return
        }
        statusView.text = getString(
            R.string.main_status_format,
            getString(CastStateStore.labelResource(state))
        )
        val authorized = isAuthorized()
        startButton.isEnabled = authorized &&
            (state == CastStateStore.State.STOPPED ||
                state == CastStateStore.State.ERROR)
        // The stop button stays enabled while Shizuku is lost: tapping it tries
        // the degraded stop and reports why it cannot work.
        stopButton.isEnabled =
            (authorized && (state == CastStateStore.State.RUNNING ||
                state == CastStateStore.State.STARTING)) ||
                state == CastStateStore.State.SHIZUKU_LOST
        requestPermissionButton.isEnabled = authorized.not() &&
            Shizuku.pingBinder() &&
            !Shizuku.isPreV11()
        statusView.setTextColor(
            when (state) {
                CastStateStore.State.RUNNING ->
                    Color.rgb(53, 224, 161)
                CastStateStore.State.ERROR ->
                    Color.rgb(255, 107, 107)
                CastStateStore.State.SHIZUKU_LOST ->
                    Color.rgb(240, 198, 116)
                CastStateStore.State.STARTING,
                CastStateStore.State.STOPPING ->
                    Color.rgb(240, 198, 116)
                else ->
                    Color.rgb(167, 182, 196)
            }
        )
    }

    private fun buildContentView(): LinearLayout {
        val padding = dp(24)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(padding, padding, padding, padding)
            setBackgroundColor(Color.rgb(10, 16, 22))
        }

        root.addView(titleView())
        root.addView(subtitleView())
        root.addView(statusCard())
        encoderFpsView = TextView(this).apply {
            setText(R.string.main_encoder_fps_idle)
            setTextColor(Color.rgb(143, 161, 177))
            textSize = 13f
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(10), 0, 0)
        }
        root.addView(
            encoderFpsView,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )
        guideView = TextView(this).apply {
            setTextColor(Color.rgb(143, 161, 177))
            textSize = 13f
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(18), 0, dp(16))
        }
        root.addView(
            guideView,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        requestPermissionButton = actionButton(R.string.shizuku_request_permission) {
            requestPermission()
        }
        root.addView(
            requestPermissionButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        openShizukuButton = actionButton(R.string.shizuku_open_app) {
            openShizukuApp()
        }
        root.addView(
            openShizukuButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(8) }
        )

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        startButton = actionButton(R.string.server_start) {
            startCaptureService()
        }
        stopButton = actionButton(R.string.server_stop) {
            stopCaptureService()
        }
        actions.addView(
            startButton,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )
        actions.addView(
            stopButton,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(10)
            }
        )
        root.addView(
            actions,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(16) }
        )

        addTileButton = actionButton(R.string.tile_add) {
            requestAddTile()
        }
        root.addView(
            addTileButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(10) }
        )

        val hint = TextView(this).apply {
            setText(R.string.main_hint)
            setTextColor(Color.rgb(112, 128, 143))
            textSize = 12f
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(24), 0, 0)
            setLineSpacing(0f, 1.4f)
        }
        root.addView(
            hint,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        root.addView(
            keepAliveCard(),
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(20) }
        )
        return root
    }

    private fun titleView(): TextView {
        return TextView(this).apply {
            setText(R.string.main_title)
            setTextColor(Color.rgb(230, 239, 247))
            textSize = 24f
            gravity = Gravity.CENTER_HORIZONTAL
        }
    }

    private fun subtitleView(): TextView {
        return TextView(this).apply {
            setText(R.string.main_subtitle)
            setTextColor(Color.rgb(143, 161, 177))
            textSize = 14f
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(10), 0, dp(24))
        }
    }

    private fun statusCard(): TextView {
        statusView = TextView(this).apply {
            textSize = 18f
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
            setBackgroundColor(Color.rgb(17, 28, 36))
        }
        return statusView
    }

    private fun actionButton(label: Int, action: () -> Unit): Button {
        return Button(this).apply {
            setText(label)
            setOnClickListener { action() }
        }
    }

    /**
     * Background-lifetime guidance.
     *
     * Custom ROMs reclaim background apps differently, so the card gives generic
     * advice on every device and only offers the OEM auto-start screen where it
     * is known to exist (the ColorOS family). The app is not tied to OPPO.
     */
    private fun keepAliveCard(): View {
        val brand = Build.MANUFACTURER.ifBlank { Build.BRAND }
        val colorOs = isColorOsFamily()
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            setBackgroundColor(Color.rgb(17, 28, 36))
        }
        card.addView(
            TextView(this).apply {
                setText(R.string.keepalive_title)
                setTextColor(Color.rgb(240, 198, 116))
                textSize = 14f
            }
        )
        card.addView(
            TextView(this).apply {
                text = if (colorOs) {
                    getString(R.string.keepalive_body_coloros, brand)
                } else {
                    getString(R.string.keepalive_body_generic, brand)
                }
                setTextColor(Color.rgb(143, 161, 177))
                textSize = 12f
                setPadding(0, dp(6), 0, dp(10))
                setLineSpacing(0f, 1.4f)
            }
        )
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        if (colorOs) {
            row.addView(
                actionButton(R.string.keepalive_autostart) { openAutoStartSettings() },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            )
        } else {
            row.addView(
                actionButton(R.string.keepalive_app_settings) { openAppDetails("") },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            )
        }
        row.addView(
            actionButton(R.string.keepalive_battery) { openBatteryOptimization() },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(10)
            }
        )
        card.addView(row)
        return card
    }

    /** True for the ColorOS family, where the OEM auto-start screen exists. */
    private fun isColorOsFamily(): Boolean {
        val names = "${Build.MANUFACTURER} ${Build.BRAND}".lowercase()
        return names.contains("oppo") || names.contains("oneplus") ||
            names.contains("realme") || names.contains("coloros")
    }

    private fun openAutoStartSettings() {
        for (flattened in AUTO_START_COMPONENTS) {
            val component = ComponentName.unflattenFromString(flattened) ?: continue
            val intent = Intent().apply {
                this.component = component
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val resolvable = try {
                packageManager.resolveActivity(intent, 0) != null
            } catch (_: Throwable) {
                false
            }
            if (!resolvable) {
                continue
            }
            try {
                startActivity(intent)
                return
            } catch (_: Throwable) {
                // Try the next ColorOS/OPPO activity name.
            }
        }
        openAppDetails("自启动管理")
    }

    private fun openBatteryOptimization() {
        val powerManager = getSystemService(PowerManager::class.java)
        if (powerManager != null &&
            powerManager.isIgnoringBatteryOptimizations(packageName)
        ) {
            Toast.makeText(this, R.string.keepalive_battery_ok, Toast.LENGTH_SHORT).show()
            return
        }
        // Opens the system "battery optimization" list, where the user can set
        // this app to Unrestricted. The direct REQUEST_IGNORE dialog is avoided
        // on purpose: it needs a Play-restricted permission for a screen the
        // user can reach from this list anyway.
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (error: Throwable) {
            openAppDetails(error.message ?: "")
        }
    }

    private fun openAppDetails(reason: String) {
        try {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")
                )
            )
        } catch (error: Throwable) {
            Toast.makeText(
                this,
                getString(R.string.keepalive_open_failed, error.message ?: reason),
                Toast.LENGTH_LONG
            ).show()
        }
    }

    private fun openShizukuApp() {
        val intent = packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE)
        if (intent == null) {
            Toast.makeText(
                this,
                R.string.shizuku_app_not_found,
                Toast.LENGTH_LONG
            ).show()
            return
        }
        try {
            startActivity(intent)
        } catch (error: Throwable) {
            Toast.makeText(
                this,
                getString(
                    R.string.shizuku_app_open_failed,
                    error.message ?: ""
                ),
                Toast.LENGTH_LONG
            ).show()
        }
    }

    private fun dp(value: Int): Int {
        return Math.round(value * resources.displayMetrics.density)
    }

    companion object {
        private const val REQUEST_CODE = 1001
        private const val REQUEST_NOTIFICATIONS = 1002
        private const val ENCODER_FPS_POLL_MS = 4_000L
        private const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"

        /**
         * Known ColorOS/OPPO auto-start management screens, newest first.
         * Unresolvable entries are skipped; the last resort is the app's own
         * details page, which exposes the same toggles on recent builds.
         */
        private val AUTO_START_COMPONENTS = listOf(
            "com.oplus.safecenter/com.oplus.safecenter.startupapp.StartupAppListActivity",
            "com.oplus.safecenter/com.oplus.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter/com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.coloros.safecenter/com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.oppo.safe/com.oppo.safe.permission.startup.StartupAppListActivity"
        )
    }
}
