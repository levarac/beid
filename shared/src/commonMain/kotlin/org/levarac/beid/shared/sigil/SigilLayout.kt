package org.levarac.beid.shared.sigil

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import org.levarac.beid.shared.aggregation.isValidAggregationTextField

/*
 * Sigil layout (beid#633, design spec "5. Proof 紋様（Sigil）の生成仕様").
 *
 * KMP ledger row (docs/kmp-shared-foundation.md section 1):
 *
 *   family: sigil layout | class: C / INVENT
 *   current_ios: none (no Sigil exists; the Proof visual is
 *     DS.Artwork.proofCardGradient, which this family does not replace)
 *   current_android: none (iOS first by owner decision; this layout is ready
 *     for an Android adapter, which must call it rather than port it)
 *   ruling_or_invariant: invariants 1-8 below | owner: beid#633 / SubPM
 *   shared_symbol: org.levarac.beid.shared.sigil.layoutSigil
 *   licensing_test: SigilLayoutTest | platform_callers: none yet (the data
 *     source is beid#653; no production screen is wired by #633)
 *
 * Ownership: this layer owns every number (angles, radii, widths, the variant,
 * ring aggregation, separation, ground geometry). The native side owns only
 * colors and the drawing calls. A native adapter must contain no geometry
 * literal and no branch that chooses a product outcome.
 *
 * The input is synthetic today. iOS does not persist per-window peer presence
 * or a cross-window peer identifier (DECISIONS 2026-09-23, "#633 紋様の入力"),
 * and presence 2 (mutual) does not exist on-device (DECISIONS 2026-08-09).
 * Nothing here infers or fabricates presence 2 from presence 1.
 *
 * Invariants (each pinned by SigilLayoutTest):
 *
 *  1. Determinism. The same input, size and ground always yield an identical
 *     layout. The angle hash is fixed and not process-seeded; see
 *     [sigilPeerHash].
 *  2. Order independence. Adding the same peers and presences in any order
 *     yields an identical layout. A duplicate (peer, window) entry resolves to
 *     the max presence. Registering a peer that already exists is a no-op that
 *     returns true: it never resets presences, so it cannot make order matter.
 *  3. Separation. After adjustment, every circularly adjacent pair of drawn
 *     peers is at least g = min(4, 360 / N) degrees apart, within 1e-9 degrees,
 *     where N is the number of peers that draw anything. If no pair is closer
 *     than g, every angle equals its base angle exactly. The circular order by
 *     (base angle, full 64-bit hash, peer key) is preserved, which also makes an
 *     exact hash-angle collision separate deterministically.
 *  4. A peer whose presence is 0 everywhere takes no angular slot. A peer's
 *     angle is identical in the full and the mini variant: the mini draws over
 *     the full variant's angle set and is never re-separated over fewer peers.
 *  5. Bounds. Every primitive, including stroke half-widths and dot radii,
 *     lies within [0, size] x [0, size] (within 1e-9) for every accepted size.
 *     Lines are bounded as if they had round caps (half-width past each end),
 *     so either cap style stays inside. The minimum accepted size,
 *     [MIN_SIGIL_SIZE] = 25, is derived from this: the outermost mini mark on a
 *     no-disc ground reaches c + 0.46 * size + 1 (half the 2-point minimum mini
 *     line width, which is also the isolated point's radius), and
 *     size / 2 + 0.46 * size + 1 <= size holds exactly when size >= 25. The full
 *     variant reaches at most 0.46 * size + 3k = 0.475 * size from the centre,
 *     so it never binds. Size <= 0, NaN and infinities are rejected.
 *  6. Boundary checks only: presence outside {1, 2} when added (0 means "do not
 *     add"), a window index outside [0, W), W outside [1, MAX_SIGIL_WINDOW_COUNT],
 *     a peer key that is empty, not valid UTF-16, or over the aggregation
 *     text-field byte limit, and the capacity caps below. A rejection returns
 *     false, or a layout with isSuccess false and an error code; never a
 *     silently empty layout.
 *  7. Presence 2 appears in the output only where the caller supplied it.
 *  8. Peer counts partition. mutualPeerCount + detectedPeerCount == peerCount,
 *     a peer being mutual when its MAX presence over the rings is 2, so a peer
 *     that is 2 in one ring and 1 in another is mutual. The counts are taken
 *     from the ring presences, never from the primitives, so they are identical
 *     in the full and the mini variant. windowCount echoes the input.
 */

/** r0 = 0.15 * size (spec 5.2). */
internal const val SIGIL_R0_FRACTION = 0.15

/** r_max on the filled-disc ground (spec 5.2). */
internal const val SIGIL_R_MAX_DISC_FRACTION = 0.41

/** r_max on every no-disc ground: outline and none (spec 5.2 "線画の場合"). */
internal const val SIGIL_R_MAX_OPEN_FRACTION = 0.46

/** k = size / 200 (spec 5.2). */
internal const val SIGIL_K_DIVISOR = 200.0

/** At or below this size the mini variant is drawn (spec 5.2 "60px 以下"). */
internal const val SIGIL_MINI_MAX_SIZE = 60.0

/** Smallest accepted size. Derived from invariant 5; do not lower it alone. */
internal const val MIN_SIGIL_SIZE = 25.0

internal const val SIGIL_MUTUAL_DOT_K = 3.0
internal const val SIGIL_DETECTED_DOT_K = 1.8
internal const val SIGIL_MUTUAL_LINE_K = 2.4
internal const val SIGIL_DETECTED_LINE_K = 1.2
internal const val SIGIL_CENTER_DOT_K = 11.0

/**
 * Ring stroke width, in k. PROVISIONAL: spec 5.2 draws rings but gives them no
 * width. One k (1 point at size 200) keeps the ring below the 1.2k detected
 * line so a ring never reads as a detection.
 */
internal const val SIGIL_RING_WIDTH_K = 1.0

internal const val SIGIL_MINI_LINE_MIN_WIDTH = 2.0
internal const val SIGIL_MINI_LINE_K = 3.4
internal const val SIGIL_MINI_CENTER_DOT_K = 16.0

/**
 * P1. Radius of an isolated presence-2 point in the mini, as a fraction of the
 * mini line width. PROVISIONAL (the designer is being asked whether it should
 * be heavier); keep it this single constant.
 */
internal const val SIGIL_MINI_POINT_RADIUS_PER_LINE_WIDTH = 0.5

/** Outline ground stroke width (spec 5.3 "外周 1.2px"), absolute, not in k. */
internal const val SIGIL_OUTLINE_WIDTH = 1.2

/**
 * P3. The outline circle's radius is size / 2 minus this inset, which is half
 * of [SIGIL_OUTLINE_WIDTH], so the stroke stays inside the bounds.
 */
internal const val SIGIL_OUTLINE_INSET = 0.6

/** Most rings ever drawn (spec 10-1: 6-12 displayed rings). */
internal const val MAX_SIGIL_RING_COUNT = 12

/** Widest minimum angular gap between drawn peers, in degrees (spec 5.2 "< 4°"). */
internal const val SIGIL_MIN_GAP_DEGREES = 4.0

/**
 * Most windows one input may declare. At the shortest ENIN window (12 s) a
 * 24-hour session is 7,200 windows and a three-day event 21,600; this leaves
 * headroom above both. Output size does not grow with it (at most 12 rings);
 * the cap only keeps the bin arithmetic and an adversarial W bounded.
 */
internal const val MAX_SIGIL_WINDOW_COUNT = 100_000

/**
 * Most distinct peers one input may hold. At 1,024 peers the gap is about
 * 0.35 degrees, under one point of arc even at the largest context (290 points,
 * r_max 119): further peers could not be told apart, so they carry no visual
 * information. It is also well above what a BLE radio sees at one venue.
 */
internal const val MAX_SIGIL_PEER_COUNT = 1024

/** Most distinct (peer, window) entries; matches the aggregation observation cap. */
internal const val MAX_SIGIL_ENTRY_COUNT = 100_000

private const val FNV_OFFSET_BASIS: ULong = 0xcbf29ce484222325uL
private const val FNV_PRIME: ULong = 0x100000001b3uL
private const val DEGREES_PER_TURN = 360

/**
 * The ground a Sigil sits on (spec 5.3). The native side paints it; this layer
 * only emits its geometry.
 *
 * - DISC: the filled ink circle (Proof Collected, Proof Detail).
 * - OUTLINE: an outer circle stroked 1.2 wide (Welcome hero).
 * - NONE: no ground (Sensing verified, list/detail minis).
 */
public enum class SigilGround { DISC, OUTLINE, NONE }

/**
 * What a primitive is, which is also the palette role the native side colors it
 * with. Listed in draw order (P2).
 */
public enum class SigilPrimitiveKind {
    /** Filled circle: (x, y) centre, radius. */
    GROUND_DISC,

    /** Stroked circle: (x, y) centre, radius, lineWidth. */
    GROUND_OUTLINE,

    /** Stroked circle: (x, y) centre, radius, lineWidth. Full variant only. */
    RING,

    /** Segment (x, y) to (x2, y2), lineWidth. Full variant only. */
    DETECTED_LINE,

    /** Segment (x, y) to (x2, y2), lineWidth. */
    MUTUAL_LINE,

    /** Filled circle. Full variant only. */
    DETECTED_DOT,

    /** Filled circle. */
    MUTUAL_DOT,

    /** Filled circle: the viewer's own device. */
    CENTER_DOT,
}

internal class SigilPeerEntries(
    val presenceByWindow: HashMap<Int, Int> = HashMap(),
)

/**
 * Opaque accumulator for one Sigil's input (spec 5.1).
 *
 * The collection stays hidden so the exported boundary remains flat, final and
 * concrete. Callers add one presence at a time and read results through the
 * layout's count / index accessors.
 */
public class SigilInput internal constructor(
    public val windowCount: Int,
) {
    internal val peers: HashMap<String, SigilPeerEntries> = HashMap()
    internal var entryCount: Int = 0

    internal val hasValidWindowCount: Boolean
        get() = windowCount >= 1 && windowCount <= MAX_SIGIL_WINDOW_COUNT
}

/**
 * One drawing primitive in a y-down space whose origin is the top-left corner
 * of a size x size square. Fields a kind does not use are: x2/y2 equal to x/y
 * for circles, radius 0 for lines, lineWidth 0 for filled circles.
 */
public class SigilPrimitive internal constructor(
    public val kind: SigilPrimitiveKind,
    public val x: Double,
    public val y: Double,
    public val x2: Double,
    public val y2: Double,
    public val radius: Double,
    public val lineWidth: Double,
)

/** A drawn peer's base angle (hash mod 360) and its angle after separation, in degrees. */
public class SigilPeerAngle internal constructor(
    public val peerKey: String,
    public val baseAngleDegrees: Int,
    public val angleDegrees: Double,
)

/**
 * A computed Sigil. Primitives are in draw order; peers are the drawn peers in
 * ascending adjusted angle. A failed layout carries isSuccess false, an error
 * code (`invalid_window_count` or `invalid_size`), and nothing to draw.
 *
 * [mutualPeerCount], [detectedPeerCount] and [windowCount] exist for the
 * accessibility summary a Sigil MUST carry (DESIGN.md 13, "7 mutual, 13
 * detected, window 6"). They are counts both platforms must agree on, so they
 * are decided here; the sentence built from them is native presentation.
 * Nothing else in this output yields them: an angle carries no presence, and
 * marks are not peers, since the full variant emits one dot PER RING and the
 * mini emits no detected mark at all. A count taken from the primitives
 * therefore over-counts in one variant and reports zero detected in the other.
 */
public class SigilLayout internal constructor(
    internal val primitives: List<SigilPrimitive>,
    internal val peers: List<SigilPeerAngle>,
    public val isSuccess: Boolean,
    public val errorCode: String?,
    public val size: Double,
    public val isMini: Boolean,
    public val ringCount: Int,
    public val windowsPerRing: Int,
    /** Drawn peers whose MAX presence over the rings is 2. 0 on a failed layout. */
    public val mutualPeerCount: Int,
    /** The remaining drawn peers, whose MAX presence is 1. 0 on a failed layout. */
    public val detectedPeerCount: Int,
    /** The input's window count, echoed. 0 on a failed layout, as [ringCount] is. */
    public val windowCount: Int,
) {
    public val primitiveCount: Int
        get() = primitives.size

    public fun primitiveAt(index: Int): SigilPrimitive? = primitives.getOrNull(index)

    public val peerCount: Int
        get() = peers.size

    public fun peerAt(index: Int): SigilPeerAngle? = peers.getOrNull(index)
}

/**
 * Creates an input for [windowCount] windows, oldest first. An out-of-range
 * count is not rejected here but makes every add return false and the layout
 * fail with `invalid_window_count`, so it can never render as "no data".
 */
public fun createSigilInput(windowCount: Int): SigilInput = SigilInput(windowCount)

/**
 * Registers a peer with presence 0 in every window. Such a peer draws nothing
 * and takes no angular slot (invariant 4). Registering an existing peer is a
 * no-op that returns true and keeps its presences. Returns false for an invalid
 * window count, an invalid key, or a new peer beyond [MAX_SIGIL_PEER_COUNT].
 */
public fun addSigilPeer(input: SigilInput, peerKey: String): Boolean {
    if (!input.hasValidWindowCount) {
        return false
    }
    if (!peerKey.isValidAggregationTextField()) {
        return false
    }
    if (input.peers.containsKey(peerKey)) {
        return true
    }
    if (input.peers.size >= MAX_SIGIL_PEER_COUNT) {
        return false
    }
    input.peers[peerKey] = SigilPeerEntries()
    return true
}

/**
 * Records that [peerKey] had [presence] (1 = detected only, 2 = mutual) in
 * window [windowIndex], registering the peer if needed. Presence 0 is "absent"
 * and is expressed by not calling this. A repeated (peer, window) keeps the max
 * presence, so insertion order never matters. Mutuality is the caller's claim
 * and is never inferred. Returns false, and changes nothing, on any boundary
 * rejection.
 */
public fun addSigilPresence(
    input: SigilInput,
    peerKey: String,
    windowIndex: Int,
    presence: Int,
): Boolean {
    if (!input.hasValidWindowCount) {
        return false
    }
    if (presence < 1 || presence > 2) {
        return false
    }
    if (windowIndex < 0 || windowIndex >= input.windowCount) {
        return false
    }
    if (!peerKey.isValidAggregationTextField()) {
        return false
    }
    val existing = input.peers[peerKey]
    if (existing == null && input.peers.size >= MAX_SIGIL_PEER_COUNT) {
        return false
    }
    val previous = existing?.presenceByWindow?.get(windowIndex)
    if (previous == null && input.entryCount >= MAX_SIGIL_ENTRY_COUNT) {
        return false
    }
    val entries = existing ?: SigilPeerEntries().also { input.peers[peerKey] = it }
    if (previous == null) {
        input.entryCount += 1
        entries.presenceByWindow[windowIndex] = presence
    } else {
        entries.presenceByWindow[windowIndex] = max(previous, presence)
    }
    return true
}

/**
 * Lays out a Sigil at [size] points on [ground]. This is a read: the input is
 * not changed and the result does not alias it.
 *
 * Variant. size <= 60 draws the mini (spec 5.2): presence-2 strands between
 * consecutive rings and isolated presence-2 points only; no rings and no
 * detected-only marks; line width max(2, 3.4k); isolated point radius per P1;
 * centre 16k. Otherwise the full variant: one ring per displayed ring, a dot for
 * every presence > 0 (3k for 2, 1.8k for 1), a line between consecutive rings
 * both > 0 (2.4k if both are 2, else 1.2k), centre 11k.
 *
 * Rings. W windows are shown as ceil(W / b) rings with b = ceil(W / 12), bins
 * anchored at window 0 (the oldest), so W <= 12 is drawn as-is and W > 12 as
 * 7-12 rings. Ring i sits at r0 + (r_max - r0) * i / (R - 1), and a single ring
 * sits at r0 (spec 5.4 divides by W - 1; this does not).
 *
 * A peer's presence in a merged ring is the MAX over the windows merged into
 * it. That is a deliberate choice, and it has a cost: a peer seen once in a
 * merged block looks identical to one seen in every window of it, and one
 * mutual window makes the whole block mutual. It never fabricates presence 2
 * (invariant 7). If the designer prefers "most common" instead, this is the
 * rule to change, and the ring vectors in SigilLayoutTest pin it.
 *
 * Coordinates. x = c + cos(theta) * r, y = c + sin(theta) * r, c = size / 2,
 * theta in degrees clockwise from +x in the y-down space (as in spec 5.4).
 *
 * Draw order (P2): ground, rings, detected lines, mutual lines, detected dots,
 * mutual dots, centre dot. Within a layer: peers by ascending adjusted angle,
 * then rings inner to outer. The reason is the distinction the mark exists to
 * carry: a mutual mark must never be painted over by a detected-only one, so
 * every mutual layer comes after its detected counterpart. Spec 5.4's reference
 * implementation interleaves marks per peer (all of one peer's lines and dots,
 * then the next peer's), which lets a later peer's detected dot cover an
 * earlier peer's mutual dot. This layer draws by layer ON PURPOSE; the
 * difference from 5.4 is not drift. Note that dots come after all lines, so a
 * detected dot can still sit on another peer's mutual LINE where two nearly
 * collinear peers cross; separation keeps that rare.
 */
public fun layoutSigil(input: SigilInput, size: Double, ground: SigilGround): SigilLayout {
    if (!input.hasValidWindowCount) {
        return failedSigilLayout("invalid_window_count", size)
    }
    if (!size.isFinite() || size < MIN_SIGIL_SIZE) {
        return failedSigilLayout("invalid_size", size)
    }

    val windowCount = input.windowCount
    val windowsPerRing = ceilDiv(windowCount, MAX_SIGIL_RING_COUNT)
    val ringCount = ceilDiv(windowCount, windowsPerRing)

    val k = size / SIGIL_K_DIVISOR
    val c = size / 2
    val r0 = size * SIGIL_R0_FRACTION
    val rMax = size * if (ground == SigilGround.DISC) SIGIL_R_MAX_DISC_FRACTION else SIGIL_R_MAX_OPEN_FRACTION
    val radii = DoubleArray(ringCount) { i ->
        if (ringCount == 1) r0 else r0 + (rMax - r0) * i / (ringCount - 1)
    }

    val ringPresence = HashMap<String, IntArray>()
    var mutualPeerCount = 0
    var detectedPeerCount = 0
    input.peers.forEach { (key, entries) ->
        val rings = IntArray(ringCount)
        entries.presenceByWindow.forEach { (window, presence) ->
            val ring = window / windowsPerRing
            rings[ring] = max(rings[ring], presence)
        }
        if (rings.any { it > 0 }) {
            ringPresence[key] = rings
            if (rings.max() == 2) {
                mutualPeerCount += 1
            } else {
                detectedPeerCount += 1
            }
        }
    }

    val angles = separatedAngles(ringPresence.keys)
    val order = ringPresence.keys.sortedWith(
        compareBy<String> { angles.getValue(it) }.then(peerOrder),
    )

    fun point(key: String, ring: Int): Pair<Double, Double> {
        val theta = angles.getValue(key) * PI / 180.0
        return Pair(c + cos(theta) * radii[ring], c + sin(theta) * radii[ring])
    }
    fun circle(kind: SigilPrimitiveKind, x: Double, y: Double, radius: Double, width: Double) =
        SigilPrimitive(kind, x, y, x, y, radius, width)
    fun segment(kind: SigilPrimitiveKind, key: String, ring: Int, width: Double): SigilPrimitive {
        val (x1, y1) = point(key, ring)
        val (x2, y2) = point(key, ring + 1)
        return SigilPrimitive(kind, x1, y1, x2, y2, 0.0, width)
    }

    val primitives = mutableListOf<SigilPrimitive>()
    when (ground) {
        SigilGround.DISC -> primitives += circle(SigilPrimitiveKind.GROUND_DISC, c, c, size / 2, 0.0)
        SigilGround.OUTLINE -> primitives += circle(
            SigilPrimitiveKind.GROUND_OUTLINE, c, c, size / 2 - SIGIL_OUTLINE_INSET, SIGIL_OUTLINE_WIDTH,
        )
        SigilGround.NONE -> Unit
    }

    val isMini = size <= SIGIL_MINI_MAX_SIZE
    if (isMini) {
        val lineWidth = max(SIGIL_MINI_LINE_MIN_WIDTH, SIGIL_MINI_LINE_K * k)
        val strands = mutableListOf<SigilPrimitive>()
        val points = mutableListOf<SigilPrimitive>()
        order.forEach { key ->
            val rings = ringPresence.getValue(key)
            for (i in 0 until ringCount) {
                if (rings[i] != 2) continue
                val next = i + 1 < ringCount && rings[i + 1] == 2
                val previous = i > 0 && rings[i - 1] == 2
                if (next) {
                    strands += segment(SigilPrimitiveKind.MUTUAL_LINE, key, i, lineWidth)
                }
                if (!next && !previous) {
                    val (x, y) = point(key, i)
                    points += circle(
                        SigilPrimitiveKind.MUTUAL_DOT, x, y, lineWidth * SIGIL_MINI_POINT_RADIUS_PER_LINE_WIDTH, 0.0,
                    )
                }
            }
        }
        primitives += strands
        primitives += points
        primitives += circle(SigilPrimitiveKind.CENTER_DOT, c, c, SIGIL_MINI_CENTER_DOT_K * k, 0.0)
    } else {
        radii.forEach { radius ->
            primitives += circle(SigilPrimitiveKind.RING, c, c, radius, SIGIL_RING_WIDTH_K * k)
        }
        val detectedLines = mutableListOf<SigilPrimitive>()
        val mutualLines = mutableListOf<SigilPrimitive>()
        val detectedDots = mutableListOf<SigilPrimitive>()
        val mutualDots = mutableListOf<SigilPrimitive>()
        order.forEach { key ->
            val rings = ringPresence.getValue(key)
            for (i in 0 until ringCount) {
                if (rings[i] == 0) continue
                if (i + 1 < ringCount && rings[i + 1] != 0) {
                    if (rings[i] == 2 && rings[i + 1] == 2) {
                        mutualLines += segment(SigilPrimitiveKind.MUTUAL_LINE, key, i, SIGIL_MUTUAL_LINE_K * k)
                    } else {
                        detectedLines += segment(SigilPrimitiveKind.DETECTED_LINE, key, i, SIGIL_DETECTED_LINE_K * k)
                    }
                }
                val (x, y) = point(key, i)
                if (rings[i] == 2) {
                    mutualDots += circle(SigilPrimitiveKind.MUTUAL_DOT, x, y, SIGIL_MUTUAL_DOT_K * k, 0.0)
                } else {
                    detectedDots += circle(SigilPrimitiveKind.DETECTED_DOT, x, y, SIGIL_DETECTED_DOT_K * k, 0.0)
                }
            }
        }
        primitives += detectedLines
        primitives += mutualLines
        primitives += detectedDots
        primitives += mutualDots
        primitives += circle(SigilPrimitiveKind.CENTER_DOT, c, c, SIGIL_CENTER_DOT_K * k, 0.0)
    }

    return SigilLayout(
        primitives = primitives,
        peers = order.map { SigilPeerAngle(it, sigilBaseAngleDegrees(it), angles.getValue(it)) },
        isSuccess = true,
        errorCode = null,
        size = size,
        isMini = isMini,
        ringCount = ringCount,
        windowsPerRing = windowsPerRing,
        mutualPeerCount = mutualPeerCount,
        detectedPeerCount = detectedPeerCount,
        windowCount = windowCount,
    )
}

/**
 * FNV-1a, 64-bit, over the peer key's UTF-8 bytes (offset 0xcbf29ce484222325,
 * prime 0x100000001b3), reduced to a base angle as an unsigned `hash mod 360`
 * in whole degrees ([sigilBaseAngleDegrees]).
 *
 * FROZEN. Changing the hash, its byte encoding or its reduction changes every
 * Sigil ever shown, so a Proof would stop looking like itself. A process-seeded
 * hash (Swift `String.hashValue` / `Hasher`, SE-0206; the precedent is
 * ios/Beid/Models/Proof.swift `deterministicSeed`) is forbidden for the same
 * reason. The literal vectors in SigilLayoutTest ARE the contract: any other
 * implementation, for example an Android port that does not call this module,
 * is expected to reproduce those vectors, not to re-derive the hash.
 */
internal fun sigilPeerHash(peerKey: String): ULong {
    var hash = FNV_OFFSET_BASIS
    peerKey.encodeToByteArray().forEach { byte ->
        hash = (hash xor byte.toUByte().toULong()) * FNV_PRIME
    }
    return hash
}

internal fun sigilBaseAngleDegrees(peerKey: String): Int =
    (sigilPeerHash(peerKey) % DEGREES_PER_TURN.toULong()).toInt()

/** Circular peer order before separation: base angle, full hash, then key. */
private val peerOrder: Comparator<String> =
    compareBy<String> { sigilBaseAngleDegrees(it) }
        .thenBy { sigilPeerHash(it) }
        .thenBy { it }

/**
 * Separates the drawn peers to at least g = min(4, 360 / N) degrees (invariant
 * 3), deterministically in hash order.
 *
 * Peers are sorted circularly by [peerOrder]. The sweep starts at the peer that
 * follows the widest gap (the first such gap on a tie), so a cluster is pushed
 * into free space rather than across it. Forward pass: each angle becomes
 * max(its base, previous + g). The last angle is then clamped to the start's
 * slot one turn later (start + 360 - g), and a backward pass sets each angle to
 * min(itself, next - g). N * g <= 360 guarantees the backward pass
 * never pushes past the start, so every adjacent gap, including the wrap, ends
 * at least g. When no gap is below g, both passes leave every base untouched.
 */
private fun separatedAngles(keys: Collection<String>): Map<String, Double> {
    val sorted = keys.sortedWith(peerOrder)
    val n = sorted.size
    if (n == 0) {
        return emptyMap()
    }
    val gap = min(SIGIL_MIN_GAP_DEGREES, DEGREES_PER_TURN.toDouble() / n)
    val bases = sorted.map { sigilBaseAngleDegrees(it).toDouble() }

    val widths = DoubleArray(n) { i ->
        (if (i + 1 < n) bases[i + 1] else bases[0] + DEGREES_PER_TURN) - bases[i]
    }
    val widest = widths.max()
    val start = (widths.indexOfFirst { it == widest } + 1) % n

    val angles = DoubleArray(n) { j ->
        val index = (start + j) % n
        if (start + j >= n) bases[index] + DEGREES_PER_TURN else bases[index]
    }
    for (j in 1 until n) {
        angles[j] = max(angles[j], angles[j - 1] + gap)
    }
    // Unconditional: without an overrun the clamp and the backward pass change
    // nothing, because the forward pass already left every gap at least g.
    angles[n - 1] = min(angles[n - 1], angles[0] + DEGREES_PER_TURN - gap)
    for (j in n - 2 downTo 1) {
        angles[j] = min(angles[j], angles[j + 1] - gap)
    }

    val result = HashMap<String, Double>()
    for (j in 0 until n) {
        result[sorted[(start + j) % n]] = angles[j] % DEGREES_PER_TURN
    }
    return result
}

private fun ceilDiv(numerator: Int, denominator: Int): Int = (numerator + denominator - 1) / denominator

private fun failedSigilLayout(errorCode: String, size: Double): SigilLayout =
    SigilLayout(
        primitives = emptyList(),
        peers = emptyList(),
        isSuccess = false,
        errorCode = errorCode,
        size = size,
        isMini = false,
        ringCount = 0,
        windowsPerRing = 0,
        mutualPeerCount = 0,
        detectedPeerCount = 0,
        windowCount = 0,
    )
