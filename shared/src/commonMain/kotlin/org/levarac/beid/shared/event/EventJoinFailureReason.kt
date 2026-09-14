package org.levarac.beid.shared.event

import org.levarac.parallax.discovery.NearbyEventJoinEligibility

/**
 * Why a join attempt did not start, in the terms a participant standing in a
 * venue can act on (beid#463).
 *
 * This is deliberately *not* the registry's error vocabulary. The registry
 * distinguishes a timeout from a 502 from an exhausted endpoint list because a
 * developer reading a log needs them apart; a participant needs one thing from
 * all three, which is to be told their device could not reach the network. The
 * whole point of the rescue route is that someone whose radio found nothing
 * has already run out of ways to tell "there is no event here" from "my phone
 * is offline" — so collapsing those two into a single "couldn't join" is the
 * defect, and collapsing five transport errors into one sentence is the fix.
 *
 * Shared rather than native so both hosts reach the same conclusion from the
 * same answer. The *wording* stays native, in each platform's string catalog:
 * this names the situation, not the sentence.
 */
public enum class EventJoinFailureReason {
    /**
     * Nothing could be verified because the device could not reach the
     * registry or the operator lookup. The one reason acceptance condition 3
     * exists for: on a fresh install with no cached definition, this is the
     * whole story, and a message that does not say so leaves the participant
     * blaming the code they were handed.
     */
    NETWORK_REQUIRED,

    /** The lookup reached its endpoint and no event is registered for this code. */
    EVENT_NOT_FOUND,

    /**
     * An answer came back and it was not for this code. Reached when a
     * canonical open code resolves to some other Event ID — see
     * [org.levarac.parallax.discovery.operatorLookupJoinEligibility] — and
     * when the code was empty.
     */
    CODE_MISMATCH,

    /** The event exists and this device may not join it now: outside its validity window, or not open admission. */
    EVENT_NOT_ACTIVE,

    /**
     * The registry answered and the answer did not verify — a digest that did
     * not match, a definition that did not decode, evidence missing its pinned
     * block — or this deployment has no registry configured to ask. Not a
     * network problem, and saying so would send the participant to look for
     * Wi-Fi that would not help.
     */
    VERIFICATION_FAILED,

    /** No classification applies. Kept explicit so an unmapped code shows up as unmapped rather than as a network error. */
    UNKNOWN,
}

/**
 * Classifies a registry or operator-lookup error code (the `errorCode` wire
 * names on `RegistryResolution`, `EventDefinitionResolution` and
 * `EventIdLookupResolution`).
 *
 * Matched on the string rather than on the enums that produce it because those
 * enums are `internal` to the registry package — a host cannot see them, and
 * the wire name is what actually crosses the seam. That means a *renamed* code
 * silently falls to [UNKNOWN] rather than being mapped wrongly, which is the
 * safe direction: an unmapped failure tells the participant less, an
 * incorrectly mapped one tells them something false.
 */
public fun eventJoinFailureReasonForRegistryErrorCode(errorCode: String?): EventJoinFailureReason =
    when (errorCode) {
        null -> EventJoinFailureReason.UNKNOWN
        // Transport. Every one of these means the answer never arrived, which
        // is one situation to a participant however many it is to a server.
        "timeout",
        "rate_limited",
        "server_error",
        "http_error",
        "no_endpoint",
        "event_code_lookup_http_error",
        "definition_http_error",
        "definition_key_set_http_error",
        -> EventJoinFailureReason.NETWORK_REQUIRED

        "event_code_lookup_not_found",
        "definition_not_found",
        -> EventJoinFailureReason.EVENT_NOT_FOUND

        else -> when {
            // A deployment that never configured a lookup endpoint, or
            // configured a malformed one, is broken for everyone and is not
            // fixed by finding Wi-Fi.
            errorCode.endsWith("_not_configured") ||
                errorCode.endsWith("_invalid_url_template") -> EventJoinFailureReason.VERIFICATION_FAILED
            errorCode.startsWith("definition_") ||
                errorCode.startsWith("event_code_lookup_") -> EventJoinFailureReason.VERIFICATION_FAILED
            errorCode == "invalid_input" ||
                errorCode == "protocol_error" ||
                errorCode == "contract_error" ||
                errorCode == "decoding_error" ||
                errorCode == "result_mismatch" ||
                errorCode == "pin_unavailable" ||
                errorCode == "strict_pin_unsupported" -> EventJoinFailureReason.VERIFICATION_FAILED
            else -> EventJoinFailureReason.UNKNOWN
        }
    }

/**
 * Classifies the join gate's own verdict, for the case where the registry
 * answered successfully and the gate still refused.
 *
 * [NearbyEventJoinEligibility.ELIGIBLE] maps to [EventJoinFailureReason.UNKNOWN]
 * on purpose: it is not a failure, so asking this function about it is already
 * a caller error, and inventing a plausible-looking reason for it would hide
 * that.
 */
public fun eventJoinFailureReasonForJoinEligibility(
    eligibility: NearbyEventJoinEligibility,
): EventJoinFailureReason = when (eligibility) {
    NearbyEventJoinEligibility.ELIGIBLE -> EventJoinFailureReason.UNKNOWN
    // Not NETWORK_REQUIRED, though it is tempting. This function is only ever
    // asked about a resolution that exists, so READ_FAILED here means an
    // answer came back carrying no definition — the network worked. A read
    // that never arrived has no resolution to classify and is classified by
    // its error code instead, which is where NETWORK_REQUIRED comes from.
    NearbyEventJoinEligibility.READ_FAILED,
    NearbyEventJoinEligibility.INCOMPLETE_REGISTRY_EVIDENCE,
    NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED,
    NearbyEventJoinEligibility.EVIDENCE_MISMATCH,
    -> EventJoinFailureReason.VERIFICATION_FAILED
    NearbyEventJoinEligibility.DEFINITION_EXPIRED,
    NearbyEventJoinEligibility.NOT_OPEN_ADMISSION,
    -> EventJoinFailureReason.EVENT_NOT_ACTIVE
    NearbyEventJoinEligibility.CODE_NOT_BOUND -> EventJoinFailureReason.CODE_MISMATCH
}

/**
 * A stable identifier for [reason], for a host that cannot switch on the enum
 * itself.
 *
 * Kotlin enums reach Swift through Swift Export as a final class carrying
 * static accessors and no `name`, no `description` and no equality — beid's
 * own `EventJoinRefusal` records this, and `SensingCoordinator` works around
 * it by logging `String(describing:)`. So iOS can obtain an
 * [EventJoinFailureReason] from the classifiers above and still have no way to
 * branch on which one it got. This gives it one.
 *
 * **This is not copy and not a presentation decision.** It is the reason's
 * identity, spelled in something every host can compare. Which reason applies
 * stays here; what to say about it stays with the host, exactly as Android
 * already does it (`EventJoinScreen.message()` maps reason to a string
 * resource, and that mapping is Android's, not `shared/`'s).
 *
 * The strings are deliberately not the enum's own `name`: an entry rename
 * would then silently change a value hosts match on. They are frozen wire
 * names, and a host's `else`/`default` branch is what catches an entry added
 * here without the host being updated.
 */
public fun eventJoinFailureReasonKey(reason: EventJoinFailureReason): String = when (reason) {
    EventJoinFailureReason.NETWORK_REQUIRED -> "network_required"
    EventJoinFailureReason.EVENT_NOT_FOUND -> "event_not_found"
    EventJoinFailureReason.CODE_MISMATCH -> "code_mismatch"
    EventJoinFailureReason.EVENT_NOT_ACTIVE -> "event_not_active"
    EventJoinFailureReason.VERIFICATION_FAILED -> "verification_failed"
    EventJoinFailureReason.UNKNOWN -> "unknown"
}
