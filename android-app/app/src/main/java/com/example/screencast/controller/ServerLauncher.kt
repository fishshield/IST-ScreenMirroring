package com.example.screencast.controller

import android.content.Context
import android.content.pm.PackageManager
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import moe.shizuku.server.IRemoteProcess
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku
import java.io.IOException

/**
 * Shizuku-backed launcher for the existing capture server.
 *
 * Shizuku 13.1.5 does not expose libsu's `Shell.Result` type. The shell
 * primitive available to an app is `IShizukuService.newProcess`; command
 * completion is therefore awaited on [Dispatchers.IO] with a hard timeout, and
 * server startup itself returns after the long-lived process is created.
 *
 * The app never implements ADB or elevation. The returned process already runs
 * with the UID/SELinux context of the Shizuku backend (shell UID 2000 for a
 * non-root Shizuku setup).
 */
class ServerLauncher private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val stateStore = CastStateStore.getInstance(appContext)
    private val mutex = Mutex()
    private val reconcileScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var process: IRemoteProcess? = null

    private val binderDeadListener = Shizuku.OnBinderDeadListener {
        // The capture server is a separate shell process and keeps streaming.
        // Losing the binder only means we can no longer *control* it, so this is
        // a UI state; nothing is stopped here.
        process = null
        stateStore.setState(CastStateStore.State.SHIZUKU_LOST)
    }

    init {
        Shizuku.addBinderDeadListener(binderDeadListener)
        // A new app process cannot own a live Shizuku newProcess handle, so the
        // persisted state may be stale in either direction: the capture server
        // (a child of the Shizuku shell) can be gone, or it can still be
        // serving while the state says STOPPED. Ask the port instead of
        // guessing. The reconciliation takes the same mutex as start/stop so a
        // tap that arrives immediately after the process starts cannot race it.
        reconcileScope.launch {
            mutex.withLock { reconcilePersistedState() }
        }
    }

    /**
     * Aligns `CastStateStore` with reality after a process restart.
     *
     * Must be called while holding [mutex]. The control port (27184) is ground
     * truth: it is opened by the capture server together with the video port
     * and closes when the server dies. A listener means the session is still
     * alive, so the tile and the activity must show RUNNING even though this
     * process has no process handle.
     */
    private fun reconcilePersistedState() {
        try {
            val listening = ServerProbe.isListeningBlocking()
            val binderUp = runCatching { Shizuku.pingBinder() }.getOrDefault(false)
            val persisted = stateStore.getState()
            val target = when {
                // Still serving but Shizuku is gone: the session must survive
                // and the UI explains that only control is lost.
                listening && !binderUp -> CastStateStore.State.SHIZUKU_LOST
                listening -> CastStateStore.State.RUNNING
                persisted == CastStateStore.State.STARTING ||
                    persisted == CastStateStore.State.RUNNING ||
                    persisted == CastStateStore.State.STOPPING ||
                    persisted == CastStateStore.State.SHIZUKU_LOST ->
                    CastStateStore.State.STOPPED
                else -> persisted
            }
            if (target != persisted) {
                Log.w(
                    TAG,
                    "reconciled persisted state $persisted -> $target " +
                        "(control port listening=$listening, binder=$binderUp)"
                )
                stateStore.setState(target)
            }
        } catch (error: Throwable) {
            Log.w(TAG, "state reconciliation failed", error)
        }
    }

    suspend fun start(): Boolean = mutex.withLock {
        if (isRunningLocked()) {
            return true
        }
        // A server may already be listening (started from ADB, or by a previous
        // app process that lost its Shizuku handle). Adopting it needs no
        // Shizuku at all and is what lets the foreground service survive a
        // Shizuku restart.
        if (ServerProbe.isListeningBlocking()) {
            Log.i(TAG, "capture server already listening; adopting it")
            stateStore.setState(
                if (runCatching { Shizuku.pingBinder() }.getOrDefault(false)) {
                    CastStateStore.State.RUNNING
                } else {
                    CastStateStore.State.SHIZUKU_LOST
                }
            )
            return true
        }
        ensureAuthorized()
        stateStore.setState(CastStateStore.State.STARTING)
        try {
            withTimeout(START_TIMEOUT_MS) {
                ensureJarInstalled()
                val remote = withContext(Dispatchers.IO) {
                    service().newProcess(
                        arrayOf("/system/bin/sh", "-c", SERVER_COMMAND),
                        null,
                        null
                    )
                }
                process = remote
                // The server creates its listener after MediaCodec/display
                // setup. Do not block the UI while that happens; the desktop
                // host has its own connect retry. Check that the process did
                // not exit immediately.
                delay(700)
                if (!alive(remote)) {
                    process = null
                    throw IllegalStateException(
                        "Capture server exited immediately; see $REMOTE_LOG"
                    )
                }
                stateStore.setState(CastStateStore.State.RUNNING)
            }
            true
        } catch (error: Throwable) {
            destroyQuietly(process)
            process = null
            stateStore.setState(CastStateStore.State.ERROR)
            throw error
        }
    }

    suspend fun stop(): Boolean = mutex.withLock {
        // A cold process (tile tap) has no Shizuku binder for a few hundred
        // milliseconds. Waiting here is what makes "stop from the tile" and
        // "stop from the app" behave the same instead of reporting a bogus
        // "Shizuku 已断开".
        val binderUp = awaitBinder()

        if (!binderUp) {
            process = null
            stateStore.setState(CastStateStore.State.STOPPING)
            // No shell identity: ask the server itself to exit over the control
            // channel. This is the stop path that works after Shizuku is gone.
            val requested = ServerShutdown.request()
            val stopped = requested && awaitNotListening(STOP_VERIFY_TIMEOUT_MS)
            stateStore.setState(
                if (stopped) {
                    CastStateStore.State.STOPPED
                } else {
                    CastStateStore.State.SHIZUKU_LOST
                }
            )
            Log.w(
                TAG,
                "stop without Shizuku: shutdown-request=$requested stopped=$stopped"
            )
            return stopped
        }
        stateStore.setState(CastStateStore.State.STOPPING)
        try {
            withTimeout(STOP_TIMEOUT_MS) {
                val current = process
                process = null
                if (current != null) {
                    withContext(Dispatchers.IO) {
                        runCatching { current.destroy() }
                    }
                }
                // Signal/destroy is the primary stop. pkill is a best-effort
                // cleanup for a process whose binder handle was lost (for
                // example a server started by the desktop over wireless ADB,
                // where this app never held a process handle).
                runCatching {
                    runShell("pkill -f $SERVER_CLASS || true")
                }
            }
            // The port is the only ground truth: `pkill` may be refused (lost
            // permission) and a stale `process` handle proves nothing. If the
            // process is still there, ask the server to exit by itself.
            var stopped = awaitNotListening(1_200L)
            if (!stopped && ServerShutdown.request()) {
                stopped = awaitNotListening(STOP_VERIFY_TIMEOUT_MS)
            }
            stateStore.setState(
                if (stopped) {
                    CastStateStore.State.STOPPED
                } else {
                    CastStateStore.State.SHIZUKU_LOST
                }
            )
            if (!stopped) {
                Log.w(TAG, "server still listens after stop; reporting failure")
            }
            return stopped
        } catch (error: Throwable) {
            process = null
            stateStore.setState(CastStateStore.State.SHIZUKU_LOST)
            Log.e(TAG, "stop failed", error)
            return false
        }
    }

    /** True once nothing listens on the control port, waiting up to [timeoutMs]. */
    private suspend fun awaitNotListening(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!ServerProbe.isListening()) {
                return true
            }
            delay(STOP_VERIFY_POLL_MS)
        }
        return !ServerProbe.isListening()
    }

    /**
     * Waits for a cold-started process to receive the Shizuku binder.
     *
     * Without this, a tile tap in a fresh process reports "Shizuku 已断开" while
     * Shizuku is actually running and merely still attaching.
     */
    private suspend fun awaitBinder(
        timeoutMs: Long = BINDER_WAIT_TIMEOUT_MS
    ): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (runCatching { Shizuku.pingBinder() }.getOrDefault(false)) {
                return true
            }
            delay(BINDER_WAIT_POLL_MS)
        }
        return runCatching { Shizuku.pingBinder() }.getOrDefault(false)
    }

    fun isRunning(): Boolean {
        val current = process ?: return false
        return try {
            current.alive()
        } catch (_: RemoteException) {
            false
        } catch (_: RuntimeException) {
            false
        }
    }

    /**
     * Best-effort `pkill` with the app's own UID.
     *
     * This normally fails because the capture server is a shell process, but it
     * is cheap and makes the degraded stop path factual rather than assumed.
     * Kept for diagnostics only; [stop] uses the control-channel shutdown.
     */
    @Suppress("unused")
    private fun tryLocalPkill(): Boolean {
        return try {
            val child = ProcessBuilder(
                "/system/bin/sh",
                "-c",
                "pkill -f $SERVER_CLASS"
            ).redirectErrorStream(true).start()
            child.waitFor() == 0
        } catch (error: Throwable) {
            Log.w(TAG, "local pkill failed", error)
            false
        }
    }

    fun close() {
        Shizuku.removeBinderDeadListener(binderDeadListener)
    }

    private fun isRunningLocked(): Boolean {
        val current = process ?: return false
        return alive(current)
    }

    private fun alive(process: IRemoteProcess): Boolean {
        return try {
            process.alive()
        } catch (_: RemoteException) {
            false
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun destroyQuietly(process: IRemoteProcess?) {
        if (process == null) {
            return
        }
        runCatching { process.destroy() }
    }

    private suspend fun ensureAuthorized() {
        check(awaitBinder()) {
            "Shizuku 未运行，请先激活 Shizuku"
        }
        check(!Shizuku.isPreV11()) {
            "当前 Shizuku 版本过旧，不支持权限 API"
        }
        if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("本应用尚未获得 Shizuku 授权")
        }
    }

    private fun service(): IShizukuService {
        check(Shizuku.pingBinder()) {
            "Shizuku binder 已断开"
        }
        val binder = Shizuku.getBinder()
            ?: throw IllegalStateException("Shizuku binder 为空")
        return IShizukuService.Stub.asInterface(binder)
            ?: throw IllegalStateException("无法连接 Shizuku 服务")
    }

    /**
     * Installs the app-bundled jar into /data/local/tmp using the shell
     * identity. The bytes are streamed into `cat`, so the app's private files
     * never need to be readable by the shell UID.
     */
    private suspend fun ensureJarInstalled() {
        val jarBytes = try {
            appContext.assets.open(JAR_ASSET).use { it.readBytes() }
        } catch (error: IOException) {
            throw IllegalStateException(
                "无法读取打包的 $JAR_ASSET",
                error
            )
        }
        if (jarBytes.isEmpty()) {
            throw IllegalStateException("打包的 server jar 为空")
        }

        // Only skip when the packaged jar is byte-identical in size. An APK
        // update can ship a newer server; reusing the old file on the device
        // would silently ignore server-side changes (e.g. --target-fps).
        val upToDate = withContext(Dispatchers.IO) {
            runShell(
                "test \"$(stat -c %s $REMOTE_JAR 2>/dev/null)\" = ${jarBytes.size}"
            )
        }
        if (upToDate == 0) {
            return
        }

        val copied = withContext(Dispatchers.IO) {
            runShell(
                "cat > $REMOTE_JAR && chmod 644 $REMOTE_JAR",
                stdin = jarBytes
            )
        }
        if (copied != 0) {
            throw IllegalStateException(
                "复制 server jar 到 $REMOTE_JAR 失败（exit=$copied）"
            )
        }
        val verified = withContext(Dispatchers.IO) {
            runShell("test -s $REMOTE_JAR")
        }
        check(verified == 0) {
            "复制后 server jar 不存在或为空"
        }
    }

    /**
     * Runs one finite shell command and returns its exit code. The remote
     * process writes stdout/stderr to its own pipes; callers that only need an
     * exit status close the stdin pipe immediately.
     */
    private suspend fun runShell(command: String, stdin: ByteArray? = null): Int {
        return withContext(Dispatchers.IO) {
            val remote = service().newProcess(
                arrayOf("/system/bin/sh", "-c", command),
                null,
                null
            )
            try {
                val output = remote.outputStream
                if (output != null) {
                    ParcelFileDescriptor.AutoCloseOutputStream(output).use { stream ->
                        if (stdin != null) {
                            stream.write(stdin)
                            stream.flush()
                        }
                    }
                }
                // The AIDL waitForTimeout is implemented in the Shizuku
                // process and returns false instead of blocking forever.
                val finished = remote.waitForTimeout(
                    COMMAND_TIMEOUT_MS,
                    "MILLISECONDS"
                )
                if (!finished) {
                    throw IllegalStateException(
                        "shell command timed out after ${COMMAND_TIMEOUT_MS}ms"
                    )
                }
                remote.exitValue()
            } finally {
                runCatching { remote.destroy() }
            }
        }
    }

    /**
     * Reads the tail of the capture server log through the shell identity.
     *
     * <p>Used by the controller UI to show the encoder rate the server itself
     * reported; no extra protocol message is involved.
     */
    suspend fun readServerLogTail(lines: Int = 120): String? = withContext(Dispatchers.IO) {
        try {
            val remote = service().newProcess(
                arrayOf("/system/bin/sh", "-c", "tail -n $lines $REMOTE_LOG"),
                null,
                null
            )
            val text = try {
                val stdout = remote.inputStream
                stdout?.let { descriptor ->
                    ParcelFileDescriptor.AutoCloseInputStream(descriptor)
                        .bufferedReader()
                        .use { reader -> reader.readText() }
                }
            } finally {
                runCatching {
                    remote.waitForTimeout(COMMAND_TIMEOUT_MS, "MILLISECONDS")
                }
                runCatching { remote.destroy() }
            }
            text
        } catch (error: Throwable) {
            Log.w(TAG, "server log read failed", error)
            null
        }
    }

    /**
     * Human-readable encoder rate line for the status card.
     *
     * <p>Parsed from the same log lines the README's baselines use:
     * `[encoder] target-fps=60 actual=59 (hint applied)` or
     * `[encoder] 1s bitrate=... frames=N ...`. This keeps the controller
     * protocol untouched.
     */
    suspend fun readEncoderFpsSummary(): String {
        val log = readServerLogTail()
            ?: return "编码帧率：无法读取服务端日志"
        val target = TARGET_FPS_PATTERN.findAll(log).lastOrNull()
        if (target != null) {
            val targetFps = target.groupValues[1]
            val actual = target.groupValues[2]
            val applied = target.groupValues[3] == "hint applied"
            return if (applied) {
                "编码帧率：${targetFps}fps（已限制，实际 ${actual}fps）"
            } else {
                "编码帧率：${targetFps}fps（提示被忽略，实际 ${actual}fps）"
            }
        }
        val stats = ENCODER_FPS_PATTERN.findAll(log).lastOrNull()
        val fps = stats?.groupValues?.get(1)
        return if (fps != null) {
            "编码帧率：${fps}fps（未限制）"
        } else {
            "编码帧率：等待编码统计…"
        }
    }

    companion object {
        private const val TAG = "ScreenCastLauncher"
        private const val JAR_ASSET = "screencast-server.jar"
        private const val REMOTE_JAR = "/data/local/tmp/screencast-server.jar"
        private const val REMOTE_LOG = "/data/local/tmp/screencast-server.log"
        private const val SERVER_CLASS =
            "com.example.screencast.server.Server"
        private const val PORT = 27183
        private const val START_TIMEOUT_MS = 30_000L
        private const val STOP_TIMEOUT_MS = 20_000L
        private const val COMMAND_TIMEOUT_MS = 10_000L

        /** Shizuku attaches asynchronously after a cold process start. */
        private const val BINDER_WAIT_TIMEOUT_MS = 2_000L
        private const val BINDER_WAIT_POLL_MS = 120L

        /** How long the stop path waits for the control port to close. */
        private const val STOP_VERIFY_TIMEOUT_MS = 3_000L
        private const val STOP_VERIFY_POLL_MS = 200L

        private const val SERVER_COMMAND =
            "CLASSPATH=$REMOTE_JAR exec /system/bin/app_process " +
                "/system/bin $SERVER_CLASS --port=$PORT " +
                "--bind-address=0.0.0.0 >$REMOTE_LOG 2>&1"

        private val TARGET_FPS_PATTERN =
            Regex("""target-fps=(\d+) actual=(\d+) \((hint applied|hint ignored by ROM)\)""")
        private val ENCODER_FPS_PATTERN =
            Regex("""\[encoder] 1s .*frames=(\d+)""")

        @Volatile
        private var instance: ServerLauncher? = null

        fun getInstance(context: Context): ServerLauncher {
            return instance ?: synchronized(this) {
                instance ?: ServerLauncher(context).also { instance = it }
            }
        }
    }
}
