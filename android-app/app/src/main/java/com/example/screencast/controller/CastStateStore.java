package com.example.screencast.controller;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Process-wide shared state between the main Activity, the Quick Settings tile
 * and the foreground service.
 *
 * <p>All of them live in the same process, so the store is a singleton: a
 * listener registered by the Activity must also receive changes made by the
 * service or the launcher. Creating one instance per component silently
 * produced "the UI only updates after switching apps" and left the tile stuck
 * on STARTING/STOPPING, because each instance kept its own listener list even
 * though the SharedPreferences file itself was shared.
 *
 * <p>SharedPreferences still keeps the value across process recreation, which
 * is why the state is persisted.
 */
public final class CastStateStore {
    public interface Listener {
        void onStateChanged(State state);
    }

    public enum State {
        UNAUTHORIZED,
        STOPPED,
        STARTING,
        RUNNING,
        STOPPING,
        ERROR,
        /**
         * The capture server is still listening, but Shizuku is gone: the
         * session keeps running and only control (stop/restart) is lost.
         */
        SHIZUKU_LOST,
    }

    private static final String PREFS_NAME = "cast_controller_state";
    private static final String KEY_STATE = "state";

    private static volatile CastStateStore instance;

    private final SharedPreferences preferences;
    private final List<Listener> listeners = new CopyOnWriteArrayList<>();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private CastStateStore(Context context) {
        preferences = context
            .getApplicationContext()
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
    }

    /** The single store for this process. */
    public static CastStateStore getInstance(Context context) {
        CastStateStore current = instance;
        if (current == null) {
            synchronized (CastStateStore.class) {
                current = instance;
                if (current == null) {
                    current = new CastStateStore(context);
                    instance = current;
                }
            }
        }
        return current;
    }

    public State getState() {
        final String raw = preferences.getString(KEY_STATE, State.UNAUTHORIZED.name());
        try {
            return State.valueOf(raw);
        } catch (IllegalArgumentException ignored) {
            return State.UNAUTHORIZED;
        }
    }

    public void setState(State state) {
        preferences.edit().putString(KEY_STATE, state.name()).apply();
        for (Listener listener : listeners) {
            mainHandler.post(() -> listener.onStateChanged(state));
        }
    }

    public void addListener(Listener listener) {
        if (!listeners.contains(listener)) {
            listeners.add(listener);
        }
    }

    public void removeListener(Listener listener) {
        listeners.remove(listener);
    }

    public static int labelResource(State state) {
        switch (state) {
            case STOPPED:
                return R.string.state_stopped;
            case STARTING:
                return R.string.state_starting;
            case RUNNING:
                return R.string.state_running;
            case STOPPING:
                return R.string.state_stopping;
            case ERROR:
                return R.string.state_error;
            case SHIZUKU_LOST:
                return R.string.state_shizuku_lost;
            case UNAUTHORIZED:
            default:
                return R.string.state_unauthorized;
        }
    }
}
