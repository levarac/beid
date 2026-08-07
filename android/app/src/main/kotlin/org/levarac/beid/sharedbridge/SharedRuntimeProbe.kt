package org.levarac.beid.sharedbridge

/*
 * CI ownership contract: this explicit cross-module import is intentionally
 * load-bearing. The stale-Kotlin compile fixture mutates this line to prove
 * that CI rejects an obsolete shared symbol. Do not remove this caller-free
 * probe until real shared API callers exist on both Android and iOS.
 */
import org.levarac.beid.shared.SharedModuleIdentity

/** Thin production call path proving the Android app links the project-local shared module. */
internal object SharedRuntimeProbe {
    fun identity(): SharedModuleIdentity = SharedModuleIdentity()
}
