package com.taocrypt.pureconnect

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject

/**
 * Fan-out of core protocol lines (JSON, one per event) from [CoreService] to
 * the Flutter UI. Remembers the last hello/state/session/flows/traffic so a
 * UI that attaches later (activity recreated, app reopened after lightweight
 * mode closed it) can catch up, plus the log lines no UI has seen.
 */
object CoreBus {
    private const val BACKLOG_MAX = 500
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val sticky = LinkedHashMap<String, String>()
    // Main thread only.
    private val backlog = ArrayDeque<String>()

    /** True while a Flutter UI listens (read from any thread). */
    @Volatile
    var uiAttached = false
        private set

    fun attach(s: EventChannel.EventSink?) {
        uiAttached = s != null
        main.post { sink = s }
    }

    fun emit(line: String) {
        val type = runCatching { JSONObject(line).optString("type") }.getOrDefault("")
        synchronized(sticky) {
            when (type) {
                "hello", "session", "state", "flows", "traffic" -> sticky[type] = line
                "exit" -> sticky.clear()
            }
        }
        main.post {
            val s = sink
            if (s != null) {
                s.success(line)
            } else if (type == "log" || type == "raw") {
                backlog.addLast(line)
                while (backlog.size > BACKLOG_MAX) backlog.removeFirst()
            } else if (type == "exit") {
                backlog.clear()
            }
        }
    }

    fun raw(message: String, level: String = "info") =
        emit(JSONObject().put("type", "raw").put("level", level).put("message", message).toString())

    fun replay() {
        val lines = synchronized(sticky) { sticky.toMap() }
        main.post {
            val s = sink ?: return@post
            for (k in listOf("hello", "state", "session")) lines[k]?.let { s.success(it) }
            while (backlog.isNotEmpty()) s.success(backlog.removeFirst())
            for (k in listOf("flows", "traffic")) lines[k]?.let { s.success(it) }
        }
    }
}
