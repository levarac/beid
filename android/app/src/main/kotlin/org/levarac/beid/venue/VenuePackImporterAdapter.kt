package org.levarac.beid.venue

import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.levarac.barnard.BarnardB005EnvelopeV2
import org.levarac.barnard.BarnardEventDefinitionV1
import org.levarac.barnard.BarnardRegistryAgreement
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.RegistryClient
import org.levarac.parallax.registry.RegistryResolution
import org.levarac.parallax.registry.safeRegistryReadPin
import org.levarac.parallax.venue.VenueVerifiedScheduling
import org.levarac.parallax.venue.classifyVenueDefinition
import org.levarac.parallax.venue.decodeVenueBundle
import org.levarac.parallax.venue.decodeVenueHandoffLink
import org.levarac.parallax.venue.decodeVenueHandoffLinkBytes
import org.levarac.parallax.venue.evaluateVenueCurrentLease
import org.levarac.parallax.venue.verifyVenueBundleIdentity
import kotlin.coroutines.resume

internal fun interface VenueBundleAcquirer {
    suspend fun acquire(url: String): ByteArray?
}

/** HTTPS-only, redirect-refusing, bounded acquisition for the public pack. */
internal class HttpsVenueBundleAcquirer : VenueBundleAcquirer {
    override suspend fun acquire(url: String): ByteArray? = withContext(Dispatchers.IO) {
        val parsed = runCatching { URI(url) }.getOrNull() ?: return@withContext null
        if (!parsed.isAbsolute || parsed.scheme.lowercase() != "https") return@withContext null
        val connection = runCatching { URL(url).openConnection() as HttpURLConnection }.getOrNull()
            ?: return@withContext null
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 30_000
            connection.readTimeout = 30_000
            if (connection.responseCode !in 200..299) return@withContext null
            if (connection.contentLengthLong > MAX_BUNDLE_BYTES) return@withContext null
            connection.inputStream.use { input ->
                val bytes = input.readNBytes(MAX_BUNDLE_BYTES + 1)
                bytes.takeIf { it.size <= MAX_BUNDLE_BYTES }
            }
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        const val MAX_BUNDLE_BYTES = 1_048_576
    }
}

/** Thin native composition: shared decodes, verifies identity, and decides readiness. */
internal class SharedVenuePackImporter(
    private val registryClient: RegistryClient?,
    private val acquirer: VenueBundleAcquirer = HttpsVenueBundleAcquirer(),
    private val nowSeconds: () -> Long = { System.currentTimeMillis() / 1_000L },
) : VenuePackImporter {
    override suspend fun import(link: String): VenueImportOutcome {
        val handoffBytes = decodeVenueHandoffLinkBytes(link) ?: return VenueImportOutcome.LinkUnreadable
        val handoff = decodeVenueHandoffLink(link) ?: return VenueImportOutcome.LinkUnreadable
        val bundleUrl = handoff.bundleUrl ?: return VenueImportOutcome.BundleAddressMissing
        val uri = runCatching { URI(bundleUrl) }.getOrNull()
        if (uri?.isAbsolute != true || uri.scheme.lowercase() != "https") {
            return VenueImportOutcome.BundleAddressUnsupported
        }
        val bundleBytes = acquirer.acquire(bundleUrl) ?: return VenueImportOutcome.FetchFailed
        val bundle = decodeVenueBundle(bundleBytes) ?: return VenueImportOutcome.VerificationFailed
        val registry = resolve(bundle.eventId.toByteArray().toHex())
            ?: return VenueImportOutcome.VerificationFailed
        val identityCheck = verifyVenueBundleIdentity(bundle, handoff, registry)
        val identity = identityCheck.identity ?: return if (identityCheck.failureCode == "handoff_mismatch") {
            VenueImportOutcome.LinkPackMismatch
        } else {
            VenueImportOutcome.VerificationFailed
        }

        // Gated/no-declaration packs cannot be projected into Barnard's B005 agreement input.
        if (classifyVenueDefinition(identity.definition).name != "OPEN_WITH_EVENT_CODE_HASH") {
            return VenueImportOutcome.VerificationFailed
        }
        val definition = identity.definition
        val eventCodeHash = definition.eventCodeHashHex?.hexBytes(8)
            ?: return VenueImportOutcome.VerificationFailed
        val barnardDefinition = BarnardEventDefinitionV1(
            eventId = definition.eventId.toByteArray(),
            keySetDigest = definition.keySetDigest.toByteArray(),
            joinMode = if (definition.joinMode == EventJoinMode.OPEN) 0 else 1,
            eventCodeHash = eventCodeHash,
            validFromUnixSeconds = definition.validFrom.value,
            validUntilUnixSeconds = definition.validUntil.value,
        )
        val now = nowSeconds()
        val candidates = ArrayList<VenueVerifiedScheduling?>(bundle.envelopeCount)
        val containers = HashMap<Int, Pair<ByteArray, String>>()
        repeat(bundle.envelopeCount) { index ->
            val signed = bundle.envelopeAt(index)
            val container = signed?.let { BarnardB005EnvelopeV2.encodeContainer(0, it) }
            val hint = container?.let(BarnardB005EnvelopeV2::schedulingFields)
            val currentEnin = hint?.eninSeconds?.takeIf { it > 0 }?.let { Math.floorDiv(now, it.toLong()) }
            val verified = container?.let { BarnardB005EnvelopeV2.verify(it, currentEnin) }
            if (verified == null || BarnardB005EnvelopeV2.registryAgreement(verified, barnardDefinition) !is BarnardRegistryAgreement.Agrees) {
                candidates += null
            } else {
                candidates += VenueVerifiedScheduling(
                    verified.validFromEnin,
                    verified.validThroughEnin,
                    verified.relayExpiresAtEnin,
                    verified.eninSeconds,
                    currentEnin!!,
                )
                containers[index] = container to verified.eventDisplayName
            }
        }
        val decision = evaluateVenueCurrentLease(identity, candidates, now)
        val lease = decision.lease ?: return VenueImportOutcome.NotReady(decision.blockCode ?: "unknown")
        val selected = containers[lease.selectedEnvelopeIndex]
            ?: return VenueImportOutcome.VerificationFailed
        return VenueImportOutcome.Ready(
            VenuePack(
                eventIdHex = bundle.eventId.toByteArray().toHex(),
                displayName = selected.second,
                validFromUnixSeconds = definition.validFrom.value,
                validUntilUnixSeconds = definition.validUntil.value,
                container = selected.first,
                stopAtUnixSeconds = lease.stopAtUnixSeconds,
            ),
        )
    }

    private suspend fun resolve(eventIdHex: String): RegistryResolution? {
        val client = registryClient ?: return null
        return suspendCancellableCoroutine { continuation ->
            val request = client.resolve(eventIdHex, safeRegistryReadPin()) {
                if (continuation.isActive) continuation.resume(it)
            }
            continuation.invokeOnCancellation { request.cancel() }
        }
    }
}

private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

private fun String.hexBytes(expectedBytes: Int): ByteArray? {
    val value = removePrefix("0x")
    if (value.length != expectedBytes * 2) return null
    return runCatching {
        ByteArray(expectedBytes) { index -> value.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }.getOrNull()
}
