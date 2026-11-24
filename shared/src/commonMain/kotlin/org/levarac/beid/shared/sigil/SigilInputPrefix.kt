package org.levarac.beid.shared.sigil

/**
 * Observed-window artwork prefix, C / INVENT (issue #735).
 * Invariant: preserve keys and earlier presences in an independent input;
 * never infer mutuality, mutate the source, or change its stored format.
 * Licensing: selected-window UI assertion and SigilInputPrefixTest vectors.
 * iOS calls this for selected-window artwork; Android has no such caller.
 * Invalid source shape/count or prefix bounds returns null, never a clamp.
 * Existing layout owns all geometry, ordering and ring recomputation.
 */
public fun sigilInputPrefixOrNull(input: SigilInput, observedWindowCount: Int): SigilInput? {
    if (!input.hasValidWindowCount || observedWindowCount !in 1..input.windowCount ||
        input.peers.size > MAX_SIGIL_PEER_COUNT
    ) {
        return null
    }
    var entryCount = 0
    for (entries in input.peers.values) {
        if (entries.presenceByWindow.size > MAX_SIGIL_ENTRY_COUNT - entryCount) return null
        entryCount += entries.presenceByWindow.size
        for ((window, presence) in entries.presenceByWindow) {
            if (window !in 0 until input.windowCount || presence !in 1..2) return null
        }
    }
    val result = createSigilInput(observedWindowCount)
    for (peer in input.peers.keys.sorted()) {
        if (!addSigilPeer(result, peer)) return null
        for ((window, presence) in input.peers.getValue(peer).presenceByWindow.entries.sortedBy { it.key }) {
            if (window < observedWindowCount && !addSigilPresence(result, peer, window, presence)) return null
        }
    }
    return result
}
