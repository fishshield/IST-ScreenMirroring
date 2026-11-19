package com.example.screencast.android

internal data class ServerConfig(
    val port: Int,
    val maxPayloadBytes: Int,
)

internal class HostLaunchRequiredException :
    IllegalStateException(
        "The capture server must be launched by host ADB so app_process runs " +
            "as the shell user (UID 2000). This plugin runs in the app process " +
            "and cannot create a UID 2000 process. Use tool/adb_launch.ps1 or " +
            "tool/adb_launch.sh; see README.md.",
    ) {
    val code: String = "HOST_LAUNCH_REQUIRED"
}

/**
 * Lifecycle seam for the external capture server.
 *
 * There is intentionally no Runtime.exec("adb ...") here: adb is a host tool,
 * and an app-UID child process would violate the UID 2000 architecture. When
 * the host/desktop topology is confirmed, wire this seam to the host launcher.
 * The socket decoder, texture registration, and FFmpeg pipeline are also TODO.
 */
internal class ServerBridge : AutoCloseable {
    @Volatile
    private var running: Boolean = false

    /**
     * Reserved for the decoder/TextureRegistry integration. Returns null until
     * a real video pipeline registers an external texture.
     */
    val previewTextureId: Int?
        get() = null

    fun start(config: ServerConfig) {
        validate(config)

        // Keep this failure explicit instead of silently launching as app UID.
        running = false
        throw HostLaunchRequiredException()
    }

    fun stop() {
        running = false
    }

    fun snapshot(): Map<String, Any?> = mapOf<String, Any?>(
        "running" to running,
        "previewTextureId" to previewTextureId,
    )

    override fun close() {
        stop()
    }

    private fun validate(config: ServerConfig) {
        require(config.port in 1024..65535) {
            "port must be between 1024 and 65535."
        }
        require(config.maxPayloadBytes in 1..MAX_PAYLOAD_BYTES) {
            "maxPayloadBytes must be between 1 and $MAX_PAYLOAD_BYTES."
        }
    }

    private companion object {
        const val MAX_PAYLOAD_BYTES = 16 * 1024 * 1024
    }
}
