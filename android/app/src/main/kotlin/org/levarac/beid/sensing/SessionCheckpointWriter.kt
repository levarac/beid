package org.levarac.beid.sensing

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import org.levarac.beid.persistence.SessionCheckpoint

/**
 * One pending immutable observation prefix, not one job or aggregate per detection.
 * Scheduling never takes the I/O lock. Boundary flushes wait for an in-flight
 * write, discard queued older work, and durably save the caller's latest prefix.
 * Recovery and finalization share that I/O lock, including signing and removal
 * of recovery input. Callers schedule work and boundary flushes on main.
 */
internal class SessionCheckpointWriter(
    private val scope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher,
    private val persist: (SessionCheckpoint) -> Unit,
    private val onFailure: (Exception) -> Unit,
) {
    private val pendingLock = Any()
    private val writeLock = Any()
    private var pending: (() -> SessionCheckpoint)? = null
    private val signals = Channel<Unit>(Channel.CONFLATED)
    private var recoveryJob: Job? = null
    private val job = scope.launch(dispatcher) {
        for (signal in signals) {
            delay(1_000)
            synchronized(writeLock) {
                val snapshot = synchronized(pendingLock) { pending.also { pending = null } }
                if (snapshot != null) {
                    try {
                        write(snapshot)
                    } catch (error: Exception) {
                        onFailure(error)
                    }
                }
            }
        }
    }

    fun schedule(snapshot: () -> SessionCheckpoint) {
        synchronized(pendingLock) { pending = snapshot }
        signals.trySend(Unit)
    }

    /** Does not depend on dispatching a coroutine while the main thread waits. */
    fun flush(snapshot: () -> SessionCheckpoint): SessionCheckpoint = synchronized(writeLock) {
        synchronized(pendingLock) { pending = null }
        write(snapshot)
    }

    /** One foreground recovery at a time; no checkpoint/store work on the caller. */
    fun reconcile(action: () -> Unit) {
        if (recoveryJob?.isActive == true) return
        recoveryJob = scope.launch(dispatcher) {
            synchronized(writeLock) {
                coroutineContext.ensureActive()
                action()
            }
        }
    }

    /** Keeps the boundary flush and final artifacts in the same transaction as recovery. */
    fun <T> serialized(action: () -> T): T = synchronized(writeLock) { action() }

    private fun write(snapshot: () -> SessionCheckpoint): SessionCheckpoint {
        val checkpoint = snapshot()
        try {
            persist(checkpoint)
        } catch (error: Exception) {
            onFailure(error)
        }
        return checkpoint
    }

    fun close() {
        job.cancel()
        recoveryJob?.cancel()
        // A running synchronous recovery must finish before disposal returns.
        synchronized(writeLock) {
            synchronized(pendingLock) { pending = null }
            signals.cancel()
        }
    }
}
