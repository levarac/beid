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
import org.levarac.beid.persistence.StoreWriteSerialization

/** Coalesces immutable prefixes; preparation is independent of session file commits. */
internal class SessionCheckpointWriter(
    private val scope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher,
    private val persist: (SessionCheckpoint) -> Unit,
    private val onFailure: (Exception) -> Unit,
    private val serialization: SessionCheckpointSerialization = SessionCheckpointSerialization(),
    private val preparePersist: (SessionCheckpoint) -> (() -> Unit) = { checkpoint -> { persist(checkpoint) } },
) {
    private val pendingLock = Any()
    private var pending: (() -> SessionCheckpoint)? = null
    private var generation = 0L
    private val signals = Channel<Unit>(Channel.CONFLATED)
    private var recoveryJob: Job? = null
    private val job = scope.launch(dispatcher) {
        for (signal in signals) {
            delay(1_000)
            coroutineContext.ensureActive()
            val (snapshot, version) = synchronized(pendingLock) {
                (pending to generation).also { pending = null }
            }
            if (snapshot != null) {
                try {
                    val commit = preparePersist(snapshot())
                    backgroundTransaction {
                        coroutineContext.ensureActive()
                        if (synchronized(pendingLock) { version == generation }) commit()
                    }
                } catch (error: Exception) {
                    onFailure(error)
                }
            }
        }
    }

    fun schedule(snapshot: () -> SessionCheckpoint) {
        synchronized(pendingLock) { pending = snapshot }
        signals.trySend(Unit)
    }

    /** Does not depend on dispatching a coroutine while the main thread waits. */
    fun flush(snapshot: () -> SessionCheckpoint): SessionCheckpoint {
        synchronized(pendingLock) { generation++; pending = null }
        val checkpoint = snapshot()
        val commit = preparePersist(checkpoint)
        serialized { commit() }
        return checkpoint
    }

    /** One foreground recovery at a time; no checkpoint/store work on the caller. */
    fun reconcile(action: suspend () -> Unit) {
        if (recoveryJob?.isActive == true) return
        recoveryJob = scope.launch(dispatcher) {
            coroutineContext.ensureActive()
            action()
        }
    }

    /** Recovery prepares without a lock and uses serialized only for reads and commits. */
    fun recover(action: () -> Unit) = action()

    /**
     * Boundary callers wait only for the transaction already running. Queued
     * background writes and recoveries must yield even if they requested the
     * lock first; simply releasing a monitor between sessions does not ensure this.
     * Reentrant so store adapters can join a file commit transaction.
     */
    fun <T> serialized(action: () -> T): T = serialization.serialized(action)

    private fun <T> backgroundTransaction(action: () -> T): T = serialization.backgroundTransaction(action)

    fun close() {
        job.cancel()
        recoveryJob?.cancel()
        // Only the in-flight transaction may delay disposal, never the backlog.
        serialized {
            synchronized(pendingLock) { generation++; pending = null }
            signals.cancel()
        }
    }
}

/** Shared by every writer touching the same checkpoint directory in this process. */
internal class SessionCheckpointSerialization : StoreWriteSerialization {
    private val writeLock = ReentrantLock()
    private val boundaryWaiters = AtomicInteger()
    private val boundaryFinished = writeLock.newCondition()

    override fun <T> serialized(action: () -> T): T {
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

    fun <T> backgroundTransaction(action: () -> T): T = writeLock.withLock {
        while (boundaryWaiters.get() > 0) boundaryFinished.await()
        action()
    }

}
