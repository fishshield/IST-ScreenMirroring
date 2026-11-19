package com.example.screencast.android

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/**
 * MethodChannel surface for the Flutter app.
 *
 * The bridge deliberately does not own an ADB client. A normal Android app
 * process cannot create a shell-UID process; see [ServerBridge] and the
 * package README before wiring a real launch path.
 */
class ScreenCastAndroidPlugin : FlutterPlugin, MethodCallHandler {
    private var channel: MethodChannel? = null
    private var serverBridge: ServerBridge? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        serverBridge = ServerBridge()
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        serverBridge?.close()
        serverBridge = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val bridge = serverBridge
        if (bridge == null) {
            result.error("E_DETACHED", "The screen-cast plugin is not attached.", null)
            return
        }

        when (call.method) {
            "startServer" -> startServer(call, bridge, result)
            "stopServer" -> {
                bridge.stop()
                result.success(bridge.snapshot())
            }
            "getPreviewTextureId" -> result.success(bridge.previewTextureId)
            "getStatus" -> result.success(bridge.snapshot())
            else -> result.notImplemented()
        }
    }

    private fun startServer(
        call: MethodCall,
        bridge: ServerBridge,
        result: MethodChannel.Result,
    ) {
        val port = call.argument<Int>("port")
        val maxPayloadBytes = call.argument<Int>("maxPayloadBytes")
        if (port == null || maxPayloadBytes == null) {
            result.error(
                "INVALID_ARGUMENTS",
                "port and maxPayloadBytes are required.",
                null,
            )
            return
        }

        try {
            bridge.start(
                ServerConfig(
                    port = port,
                    maxPayloadBytes = maxPayloadBytes,
                ),
            )
            result.success(bridge.snapshot())
        } catch (error: HostLaunchRequiredException) {
            result.error(error.code, error.message, null)
        } catch (error: IllegalArgumentException) {
            result.error("INVALID_ARGUMENTS", error.message, null)
        } catch (error: Exception) {
            result.error(
                "INTERNAL_ERROR",
                error.message ?: error.javaClass.simpleName,
                null,
            )
        }
    }

    companion object {
        const val CHANNEL = "dev.screencast/control"
    }
}
