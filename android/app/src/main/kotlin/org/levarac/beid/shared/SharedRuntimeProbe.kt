package org.levarac.beid.shared

/** Thin production call path proving the Android app links the project-local shared module. */
internal object SharedRuntimeProbe {
    fun identity(): SharedModuleIdentity = SharedModuleIdentity()
}
