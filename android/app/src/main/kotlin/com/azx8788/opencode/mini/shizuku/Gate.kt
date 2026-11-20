package com.azx8788.opencode.mini.shizuku

/** Cancellation can arrive before execute's Binder transaction. Never forget that tombstone. */
internal class ServiceGate(private val capacity: Int = 4096) {
    private val claimed = mutableSetOf<String>()
    private val cancelled = mutableSetOf<String>()
    private var active: String? = null
    private var stopping = false

    @Synchronized fun claim(id: String): String? = when {
        stopping -> "service_stopping"
        id in cancelled -> "cancelled_before_start"
        id in claimed -> "duplicate_operation"
        active != null -> "busy"
        (claimed + cancelled).size >= capacity -> "operation_history_full"
        else -> { claimed.add(id); active = id; null }
    }

    @Synchronized fun cancelled(id: String) = stopping || id in cancelled
    @Synchronized fun cancel(id: String): Boolean {
        if (id !in claimed && id !in cancelled && (claimed + cancelled).size >= capacity) return false
        cancelled.add(id)
        return true
    }
    @Synchronized fun finish(id: String) { if (active == id) active = null }
    @Synchronized fun stop() { stopping = true }
}
