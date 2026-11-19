package com.example.screencast.controller

import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * LAN discovery beacon: tells a desktop host on the same network that this
 * phone is serving a capture session.
 *
 * The datagram is deliberately secret-free:
 *
 * ```json
 * {"type":"screencast-offer","ip":"192.168.1.134",
 *  "videoPort":27183,"controlPort":27184,"pskRequired":false}
 * ```
 *
 * It is sent once per second for five seconds, to UDP/27185, from every
 * non-loopback IPv4 interface through that interface's own broadcast address.
 * The `ip` field is the address of the interface the packet leaves from, so a
 * multi-homed phone advertises the right address per network.
 *
 * Nothing here can break capture: an unreachable or absent desktop just means
 * nobody listens. The actual session is still TCP + the existing record layer,
 * and the PSK never travels over UDP.
 */
object DiscoveryBroadcaster {
    private const val TAG = "ScreenCastDiscovery"

    const val DISCOVERY_PORT = 27185
    const val VIDEO_PORT = 27183
    const val CONTROL_PORT = 27184

    private const val ROUNDS = 5
    private const val INTERVAL_MS = 1000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Coalesces repeated calls (tile tap + foreground service start). */
    private val running = AtomicBoolean(false)

    /**
     * Starts a five second announcement burst unless one is already running.
     *
     * [pskRequired] must describe the *running* server, not the app settings:
     * the Shizuku launcher starts the server without `--psk-hex`, so the
     * shipped configuration advertises false.
     */
    fun announce(pskRequired: Boolean = false) {
        if (!running.compareAndSet(false, true)) {
            return
        }
        scope.launch {
            try {
                burst(pskRequired)
            } catch (error: Throwable) {
                Log.w(TAG, "discovery burst failed", error)
            } finally {
                running.set(false)
            }
        }
    }

    private suspend fun burst(pskRequired: Boolean) {
        val targets = broadcastTargets()
        if (targets.isEmpty()) {
            Log.w(TAG, "no IPv4 broadcast interface; discovery offer skipped")
            return
        }
        DatagramSocket().use { socket ->
            socket.broadcast = true
            for (round in 0 until ROUNDS) {
                var sent = 0
                for (target in targets) {
                    try {
                        val payload = buildPayload(
                            target.local.hostAddress ?: continue,
                            pskRequired
                        ).toByteArray(Charsets.UTF_8)
                        socket.send(
                            DatagramPacket(
                                payload,
                                payload.size,
                                target.broadcast,
                                DISCOVERY_PORT
                            )
                        )
                        sent++
                    } catch (error: Throwable) {
                        Log.w(TAG, "offer send failed on ${target.local}", error)
                    }
                }
                Log.i(
                    TAG,
                    "screencast offer round ${round + 1}/$ROUNDS sent to " +
                        "$sent/${targets.size} interface(s)"
                )
                if (round < ROUNDS - 1) {
                    delay(INTERVAL_MS)
                }
            }
        }
    }

    /** One local IPv4 address plus the broadcast address of its subnet. */
    private class Target(val local: Inet4Address, val broadcast: InetAddress)

    /**
     * Every up, non-loopback IPv4 interface that has a broadcast address.
     * Link-local (169.254/16) addresses are skipped: they only reach the local
     * link and the desktop filters them anyway.
     */
    private fun broadcastTargets(): List<Target> {
        val result = ArrayList<Target>()
        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()
        } catch (error: Throwable) {
            Log.w(TAG, "interface enumeration failed", error)
            return result
        } ?: return result

        for (networkInterface in Collections.list(interfaces)) {
            val up = try {
                networkInterface.isUp
            } catch (_: Throwable) {
                false
            }
            if (!up || networkInterface.isLoopback) {
                continue
            }
            val addresses = try {
                networkInterface.interfaceAddresses
            } catch (_: Throwable) {
                continue
            }
            for (interfaceAddress in addresses) {
                val local = interfaceAddress.address as? Inet4Address ?: continue
                if (local.isLoopbackAddress || local.isLinkLocalAddress) {
                    continue
                }
                val broadcast = interfaceAddress.broadcast ?: continue
                result.add(Target(local, broadcast))
            }
        }
        return result
    }

    /** JSON body of one announcement; exposed for the JVM unit tests. */
    fun buildPayload(ip: String, pskRequired: Boolean): String {
        return JSONObject().apply {
            put("type", "screencast-offer")
            put("ip", ip)
            put("videoPort", VIDEO_PORT)
            put("controlPort", CONTROL_PORT)
            put("pskRequired", pskRequired)
        }.toString()
    }
}
