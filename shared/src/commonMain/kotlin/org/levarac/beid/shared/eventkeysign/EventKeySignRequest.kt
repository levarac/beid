package org.levarac.beid.shared.eventkeysign

/**
 * The one entry point through which a web page may obtain a signature by a
 * participant's per-event Barnard signing key (the ObservationV1 `observer`).
 *
 * A page opens `beid://event-key-sign?v=1&p=<purpose>&e=<eventId>&b=<body>&st=<state>[&k=<eventKey>]`.
 * This file decides whether that link is acceptable and which exact bytes the
 * native side signs; native code resolves the event, asks the participant,
 * calls Barnard, and opens the compiled-in callback. Both apps must agree on
 * the bytes, which is why the layout lives here.
 *
 * Signed message (mizar `docs/design/spec.md`, "App signature"):
 *
 * ```
 * M = 0xFF ‖ "beid/event-key-sign/v1" ‖ 0x00 ‖ purpose ‖ eventId(32) ‖ body
 *   purpose 0x01: body = challenge(32)                                   |M| = 89
 *   purpose 0x02: body = chainId(uint256) ‖ claimContract(20) ‖ recipient(20)  |M| = 129
 * ```
 *
 * Barnard signs `SHA256(M)`, which Solidity rebuilds as
 * `sha256(abi.encodePacked(bytes1(0xff), "beid/event-key-sign/v1", bytes1(0x00), uint8(purpose), eventId, ...body))`.
 *
 * **A leading 0xFF is reserved for this entry point.** Every other message the
 * event key signs starts with something else: the COSE `Sig_structure` of an
 * ObservationV1 starts 0x84, the legacy WindowReport starts with the UTF-8
 * event code, and Barnard's own proofs start with an ASCII `barnard-` tag.
 * 0xFF can begin neither CBOR nor UTF-8, so no signature obtained here can be
 * presented as any of those. A future event-key message format must not start
 * with 0xFF.
 *
 * There is deliberately no callback parameter: the result goes only to the
 * https URL the app was built with for that purpose, so a link cannot name
 * where a signature is sent.
 */
public enum class EventKeySignPurpose(public val code: Int) {
    PERSONHOOD_BINDING(1),
    CLAIM(2),
}

public enum class EventKeySignRejection {
    NOT_EVENT_KEY_SIGN_LINK,
    MALFORMED_QUERY,
    DUPLICATE_PARAMETER,
    UNKNOWN_PARAMETER,
    UNSUPPORTED_VERSION,
    UNKNOWN_PURPOSE,
    INVALID_EVENT_ID,
    INVALID_BODY,
    INVALID_STATE,
    INVALID_EVENT_KEY,
}

public sealed interface EventKeySignParseResult {
    public class Accepted(public val request: EventKeySignRequest) : EventKeySignParseResult

    public class Rejected(public val reason: EventKeySignRejection) : EventKeySignParseResult
}

/**
 * A validated request. Hex fields are lowercase; `eventIdHex` and
 * `expectedEventKeyHex` carry no `0x` prefix, the two addresses do.
 */
public class EventKeySignRequest internal constructor(
    public val purpose: EventKeySignPurpose,
    public val eventIdHex: String,
    public val state: String,
    public val expectedEventKeyHex: String?,
    private val bodyHex: String,
) {
    /** Purpose 0x01 only. */
    public val challengeHex: String? =
        if (purpose == EventKeySignPurpose.PERSONHOOD_BINDING) bodyHex else null

    /** Purpose 0x02 only, as a decimal string for display. */
    public val chainIdDecimal: String? =
        if (purpose == EventKeySignPurpose.CLAIM) bodyHex.substring(0, 64).toLong(16).toString() else null

    /** Purpose 0x02 only. */
    public val claimContractHex: String? =
        if (purpose == EventKeySignPurpose.CLAIM) "0x" + bodyHex.substring(64, 104) else null

    /** Purpose 0x02 only. */
    public val recipientHex: String? =
        if (purpose == EventKeySignPurpose.CLAIM) "0x" + bodyHex.substring(104, 144) else null

    /** The exact bytes of M, as lowercase hex, for the native signer. */
    public fun messageHex(): String =
        MESSAGE_PREFIX_HEX + purpose.code.toString(16).padStart(2, '0') + eventIdHex + bodyHex
}

public fun parseEventKeySignLink(link: String): EventKeySignParseResult {
    if (!link.startsWith(LINK_PREFIX)) return rejected(EventKeySignRejection.NOT_EVENT_KEY_SIGN_LINK)
    val rest = link.substring(LINK_PREFIX.length)
    if (rest.isNotEmpty() && rest[0] != '?') return rejected(EventKeySignRejection.NOT_EVENT_KEY_SIGN_LINK)
    val query = rest.removePrefix("?")
    if (query.isEmpty() || query.any { !it.isQueryCharacter() }) {
        return rejected(EventKeySignRejection.MALFORMED_QUERY)
    }

    val parameters = mutableMapOf<String, String>()
    for (pair in query.split('&')) {
        val separator = pair.indexOf('=')
        if (separator <= 0 || separator == pair.length - 1) return rejected(EventKeySignRejection.MALFORMED_QUERY)
        val name = pair.substring(0, separator)
        val value = pair.substring(separator + 1)
        if ('=' in value) return rejected(EventKeySignRejection.MALFORMED_QUERY)
        if (name !in KNOWN_PARAMETERS) return rejected(EventKeySignRejection.UNKNOWN_PARAMETER)
        if (parameters.put(name, value) != null) return rejected(EventKeySignRejection.DUPLICATE_PARAMETER)
    }

    if (parameters["v"] != "1") return rejected(EventKeySignRejection.UNSUPPORTED_VERSION)
    val purpose = when (parameters["p"]) {
        "01" -> EventKeySignPurpose.PERSONHOOD_BINDING
        "02" -> EventKeySignPurpose.CLAIM
        else -> return rejected(EventKeySignRejection.UNKNOWN_PURPOSE)
    }
    val eventIdHex = canonicalHex(parameters["e"], EVENT_ID_BYTES)
        ?: return rejected(EventKeySignRejection.INVALID_EVENT_ID)
    val bodyHex = canonicalHex(parameters["b"], purpose.bodyBytes())
        ?.takeIf { purpose.acceptsBody(it) }
        ?: return rejected(EventKeySignRejection.INVALID_BODY)
    val state = parameters["st"]?.takeIf { it.isValidState() }
        ?: return rejected(EventKeySignRejection.INVALID_STATE)
    val expectedEventKeyHex = parameters["k"]?.let { raw ->
        canonicalHex(raw, COMPRESSED_KEY_BYTES)?.takeIf { it.startsWith("02") || it.startsWith("03") }
            ?: return rejected(EventKeySignRejection.INVALID_EVENT_KEY)
    }

    return EventKeySignParseResult.Accepted(
        EventKeySignRequest(purpose, eventIdHex, state, expectedEventKeyHex, bodyHex),
    )
}

/**
 * The URL fragment the native side appends to the purpose's callback after a
 * successful signature. `sig` is `r ‖ s ‖ v` with `v = recoveryId + 27`, the
 * 65-byte form OpenZeppelin `ECDSA.recover(bytes32, bytes)` accepts. Returns
 * null when any input is outside that profile, so a malformed result is never
 * handed to a page.
 */
public fun eventKeySignSuccessFragment(
    state: String,
    rHex: String,
    sHex: String,
    recoveryId: Int,
    eventKeyHex: String,
    eventKeyAddressHex: String,
): String? {
    if (!state.isValidState()) return null
    if (recoveryId != 0 && recoveryId != 1) return null
    val r = canonicalHex(rHex, 32) ?: return null
    val s = canonicalHex(sHex, 32) ?: return null
    val key = canonicalHex(eventKeyHex, COMPRESSED_KEY_BYTES) ?: return null
    val address = canonicalHex(eventKeyAddressHex, 20) ?: return null
    val v = (recoveryId + 27).toString(16).padStart(2, '0')
    return "v=1&st=$state&sig=0x$r$s$v&k=0x$key&a=0x$address"
}

/** The URL fragment for a request the participant declined. */
public fun eventKeySignCancelledFragment(state: String): String? =
    if (state.isValidState()) "v=1&st=$state&err=cancelled" else null

private const val LINK_PREFIX = "beid://event-key-sign"
private const val MESSAGE_PREFIX_HEX = "ff626569642f6576656e742d6b65792d7369676e2f763100"
private const val EVENT_ID_BYTES = 32
private const val COMPRESSED_KEY_BYTES = 33
private const val MAX_STATE_LENGTH = 64
private val KNOWN_PARAMETERS = setOf("v", "p", "e", "b", "st", "k")

private fun rejected(reason: EventKeySignRejection) = EventKeySignParseResult.Rejected(reason)

private fun EventKeySignPurpose.bodyBytes(): Int = when (this) {
    EventKeySignPurpose.PERSONHOOD_BINDING -> 32
    EventKeySignPurpose.CLAIM -> 72
}

private fun EventKeySignPurpose.acceptsBody(bodyHex: String): Boolean = when (this) {
    EventKeySignPurpose.PERSONHOOD_BINDING -> true
    EventKeySignPurpose.CLAIM -> {
        val chainId = bodyHex.substring(0, 64)
        // A chain id must be non-zero and fit a signed 64-bit value so it can
        // be shown to the participant exactly; no real chain id is larger.
        chainId.substring(0, 48).all { it == '0' } &&
            chainId[48] in '0'..'7' &&
            chainId.any { it != '0' } &&
            bodyHex.substring(64, 104).any { it != '0' } &&
            bodyHex.substring(104, 144).any { it != '0' }
    }
}

/** Lowercase hex of exactly [bytes] bytes, with an optional `0x` prefix accepted on input. */
private fun canonicalHex(raw: String?, bytes: Int): String? {
    val digits = raw?.removePrefix("0x") ?: return null
    if (digits.length != bytes * 2) return null
    if (!digits.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
    return digits.lowercase()
}

private fun String.isValidState(): Boolean =
    length in 1..MAX_STATE_LENGTH && all { it.isStateCharacter() }

private fun Char.isStateCharacter(): Boolean =
    this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9' || this == '-' || this == '_'

// Every legitimate value is hex, a small integer or a base64url state, so no
// percent-decoding is ever needed; anything else is refused rather than decoded.
private fun Char.isQueryCharacter(): Boolean = isStateCharacter() || this == '&' || this == '='
