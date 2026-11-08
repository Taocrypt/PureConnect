package com.taocrypt.pureconnect

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject

/**
 * Fan-out of core protocol lines (JSON, one per event) from [CoreService] to
 * the Flutter UI. Remembers the last hello/state/session so a UI that attaches
 * later (activity recreated, app reopened) can catch up.
 */
object CoreBus {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val sticky = LinkedHashMap<String, String>()

    fun attach(s: EventChannel.EventSink?) {
        main.post { sink = s }
    }

    fun emit(line: String) {
        val type = runCatching { JSONObject(line).optString("type") }.getOrDefault("")
        synchronized(sticky) {
            when (type) {
                "hello", "session" -> sticky[type] = line
                "state" -> sticky["state"] = line
                "exit" -> sticky.clear()
            }
        }
        main.post { sink?.success(line) }
    }

    fun raw(message: String, level: String = "info") =
        emit(JSONObject().put("type", "raw").put("level", level).put("message", message).toString())

    fun replay() {
        val lines = synchronized(sticky) { sticky.values.toList() }
        main.post { lines.forEach { sink?.success(it) } }
    }
}
