package org.levarac.beid.sensing

import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

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
    private val writeLock = ReentrantLock()
    private val boundaryWaiters = AtomicInteger()
    private val boundaryFinished = writeLock.newCondition()
    private var pending: (() -> SessionCheckpoint)? = null
    private val signals = Channel<Unit>(Channel.CONFLATED)
    private var recoveryJob: Job? = null
    private val job = scope.launch(dispatcher) {
        for (signal in signals) {
            delay(1_000)
            backgroundTransaction {
                coroutineContext.ensureActive()
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
    fun flush(snapshot: () -> SessionCheckpoint): SessionCheckpoint = serialized {
        synchronized(pendingLock) { pending = null }
        write(snapshot)
    }

    /** One foreground recovery at a time; no checkpoint/store work on the caller. */
    fun reconcile(action: suspend () -> Unit) {
        if (recoveryJob?.isActive == true) return
        recoveryJob = scope.launch(dispatcher) {
            coroutineContext.ensureActive()
            action()
        }
    }

    /** One checkpoint's read, signing, final artifacts and removal are indivisible. */
    fun recover(action: () -> Unit) = backgroundTransaction(action)

    /**
     * Boundary callers wait only for the transaction already running. Queued
     * background writes and recoveries must yield even if they requested the
     * lock first; simply releasing a monitor between sessions does not ensure this.
     * Reentrant so finalization can include its flush in the same transaction.
     */
    fun <T> serialized(action: () -> T): T {
        boundaryWaiters.incrementAndGet()
        return writeLock.withLock {
            try {
                action()
            } finally {
                boundaryWaiters.decrementAndGet()
                boundaryFinished.signalAll()
            }
        }
    }

    private fun <T> backgroundTransaction(action: () -> T): T = writeLock.withLock {
        while (boundaryWaiters.get() > 0) boundaryFinished.await()
        action()
    }

    private fun write(snapshot: () -> SessionCheckpoint): SessionCheckpoint {
        val checkpoint = snapshot()
        persist(checkpoint)
        return checkpoint
    }

    fun close() {
        job.cancel()
        recoveryJob?.cancel()
        // Only the in-flight transaction may delay disposal, never the backlog.
        serialized {
            synchronized(pendingLock) { pending = null }
            signals.cancel()
        }
    }
}
