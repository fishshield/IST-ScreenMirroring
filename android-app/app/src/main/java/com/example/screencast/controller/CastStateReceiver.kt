package com.example.screencast.controller

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.service.quicksettings.TileService
import android.util.Log
import rikka.shizuku.Shizuku

/**
 * Keeps the controller app's view of the session in sync when the *desktop*
 * starts or stops the capture server over ADB.
 *
 * <p>Only the phone app can update its Quick Settings tile, but a desktop
 * connection starts `app_process` over wireless ADB without involving the app.
 * [com.example.screencast.controller.ServerLauncher] can therefore not observe
 * it; the desktop sends this broadcast instead (guarded by the DUMP permission,
 * which the adb shell holds).
 *
 * <p>After updating the shared state store the receiver asks SystemUI to rebind
 * the tile, so the label changes even if the panel is not open.
 */
class CastStateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val store = CastStateStore.getInstance(context)
        when (action) {
            ACTION_SERVER_STARTED -> {
                // A running server without a Shizuku binder is still casting;
                // it only cannot be controlled through Shizuku.
                val binderUp = runCatching { Shizuku.pingBinder() }
                    .getOrDefault(false)
                store.setState(
                    if (binderUp) {
                        CastStateStore.State.RUNNING
                    } else {
                        CastStateStore.State.SHIZUKU_LOST
                    }
                )
                Log.i(TAG, "desktop reported a running session (binder=$binderUp)")
            }
            ACTION_SERVER_STOPPED -> {
                store.setState(CastStateStore.State.STOPPED)
                Log.i(TAG, "desktop reported the session ended")
            }
            else -> return
        }
        // Force SystemUI to (re)bind the tile so it repaints from the store.
        runCatching {
            TileService.requestListeningState(
                context,
                ComponentName(context, ScreenCastTileService::class.java)
            )
        }
    }

    companion object {
        private const val TAG = "ScreenCastReceiver"
        const val ACTION_SERVER_STARTED =
            "com.example.screencast.action.SERVER_STARTED"
        const val ACTION_SERVER_STOPPED =
            "com.example.screencast.action.SERVER_STOPPED"
    }
}
