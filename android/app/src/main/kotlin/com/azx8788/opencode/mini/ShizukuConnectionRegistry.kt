package com.azx8788.opencode.mini

/** Tracks the one live ServiceConnection; a late callback may only detach its own epoch. */
internal class ShizukuConnectionRegistry<C : Any> {
    data class Entry<C>(val epoch: Long, val connection: C)

    private var current: Entry<C>? = null

    @Synchronized fun install(epoch: Long, connection: C) {
        current = Entry(epoch, connection)
    }

    @Synchronized fun isCurrent(epoch: Long, connection: C): Boolean =
        current?.let { it.epoch == epoch && it.connection === connection } == true

    @Synchronized fun take(epoch: Long, connection: C): Entry<C>? {
        val active = current ?: return null
        if (active.epoch != epoch || active.connection !== connection) return null
        current = null
        return active
    }

    @Synchronized fun take(epoch: Long): Entry<C>? {
        val active = current ?: return null
        if (active.epoch != epoch) return null
        current = null
        return active
    }

    @Synchronized fun takeCurrent(): Entry<C>? = current.also { current = null }
}
