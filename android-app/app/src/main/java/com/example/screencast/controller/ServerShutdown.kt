package com.example.screencast.controller

import android.util.Log
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Asks the capture server to exit through its own control channel.
 *
 * The capture process runs as the shell user (UID 2000), so an ordinary app
 * cannot kill it with `pkill`; this is the stop path that keeps working after
 * Shizuku is gone (or when the server was started by the desktop over wireless
 * ADB and this app never held a process handle).
 *
 * The frame is the same control envelope used for input: one type byte
 * (`0x10`), a 4-byte payload length (0) and no payload. Older servers log
 * "unknown message type" and ignore it, which is why the app verifies the port
 * afterwards instead of trusting the send.
 */
object ServerShutdown {
    private const val TAG = "ScreenCastShutdown"
    private const val TYPE_SHUTDOWN = 0x10
    private const val CONNECT_TIMEOUT_MS = 500

    /** Sends the one-way shutdown request; true when it reached the server. */
    fun request(
        port: Int = ServerProbe.CONTROL_PORT,
        timeoutMs: Int = CONNECT_TIMEOUT_MS
    ): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), timeoutMs)
                val output: OutputStream = socket.getOutputStream()
                output.write(
                    byteArrayOf(TYPE_SHUTDOWN.toByte(), 0, 0, 0, 0)
                )
                output.flush()
                socket.shutdownOutput()
            }
            true
        } catch (error: Throwable) {
            Log.w(TAG, "shutdown request failed: ${error.message}")
            false
        }
    }
}
