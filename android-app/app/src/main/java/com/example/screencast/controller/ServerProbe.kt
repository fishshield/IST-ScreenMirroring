package com.example.screencast.controller

import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Cheap liveness probe for the capture server.
 *
 * `CastStateStore` is only a cache: the persisted state can keep claiming
 * RUNNING after the `app_process` capture server is gone (Shizuku restarted,
 * external `pkill`, OOM kill). Before the tile acts on a tap it asks the OS
 * instead of the cache — a TCP connect to the loopback control port succeeds
 * only while something is actually listening.
 *
 * The probe connects and closes immediately; the control server treats that as
 * a normal "control disconnected" and it never creates a virtual display
 * (unlike a probe of the video port, which would start a capture session).
 */
object ServerProbe {
    const val CONTROL_PORT = 27184

    suspend fun isListening(
        port: Int = CONTROL_PORT,
        timeoutMs: Int = 400
    ): Boolean = withContext(Dispatchers.IO) {
        isListeningBlocking(port, timeoutMs)
    }

    /** Blocking variant for callers that already run off the main thread. */
    fun isListeningBlocking(
        port: Int = CONTROL_PORT,
        timeoutMs: Int = 400
    ): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), timeoutMs)
            }
            true
        } catch (_: Throwable) {
            false
        }
    }
}
