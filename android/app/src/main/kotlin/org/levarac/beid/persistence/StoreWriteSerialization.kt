package org.levarac.beid.persistence

/** Native storage effects share the session transaction without owning product decisions. */
internal interface StoreWriteSerialization {
    fun <T> serialized(action: () -> T): T
}

internal object DirectStoreWrites : StoreWriteSerialization {
    override fun <T> serialized(action: () -> T): T = action()
}
