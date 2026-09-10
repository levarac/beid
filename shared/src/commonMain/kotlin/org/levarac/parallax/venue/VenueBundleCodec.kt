package org.levarac.parallax.venue

import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.ImmutableBytes
import org.levarac.parallax.registry.Address20
import org.levarac.parallax.registry.EventDefinitionCborCodec.StrictCborReader
import org.levarac.parallax.registry.Sha256

/** Returns null for malformed input; success is structural, never permission to serve. */
public fun decodeVenueBundle(bytes: ByteArray): VenueBundle? = try {
    require(bytes.size <= MAX_VENUE_BUNDLE_BYTES)
    // Parsing and hashing must see the same snapshot, even if the caller retains its array.
    val encoded = bytes.copyOf()
    val reader = StrictCborReader(encoded)
    reader.expectMap(10)
    reader.expectUnsignedKey(1)
    require(reader.readUnsigned() == 1L)
    reader.expectUnsignedKey(2)
    val chainId = reader.readProtocolUInt("chainId").value
    reader.expectUnsignedKey(3)
    val eventRegistry = Address20(reader.readByteString(20))
    reader.expectUnsignedKey(4)
    val definitionRegistry = Address20(reader.readByteString(20))
    reader.expectUnsignedKey(5)
    val eventId = ByteString32(reader.readByteString(32))
    reader.expectUnsignedKey(6)
    val sequence = reader.readProtocolUInt("definitionSequence").value
    require(sequence >= 1)
    reader.expectUnsignedKey(7)
    val definitionDigest = ByteString32(reader.readByteString(32))
    reader.expectUnsignedKey(8)
    val signedDefinition = ImmutableBytes(reader.readByteString())
    reader.expectUnsignedKey(9)
    val keySet = ImmutableBytes(reader.readByteString())
    reader.expectUnsignedKey(10)
    val envelopes = readBoundedEnvelopes(reader)
    reader.requireFinished()
    VenueBundle(
        chainId, eventRegistry, definitionRegistry, eventId, sequence, definitionDigest,
        signedDefinition, keySet, envelopes,
        ByteString32(Sha256.digest(BUNDLE_DIGEST_DOMAIN.encodeToByteArray() + encoded)),
    )
} catch (_: IllegalArgumentException) {
    null
}

// Internal so tests can witness these guards independently of VenueBundle's
// constructor. Keep the count guard before List(count): the CBOR declaration
// is untrusted and the whole-input byte limit does not bound its declared count.
internal fun readBoundedEnvelopes(reader: StrictCborReader): List<ByteArray> {
    val count = reader.readArrayLength()
    require(count in 1..MAX_VENUE_ENVELOPES)
    return List(count) {
        reader.readByteString().also {
            require(it.size in MIN_VENUE_ENVELOPE_BYTES..MAX_VENUE_ENVELOPE_BYTES)
        }
    }
}

/** Decodes the expected values carried in a sidecar file. */
public fun decodeVenueHandoff(bytes: ByteArray): VenueHandoff? = try {
    require(bytes.size <= MAX_VENUE_HANDOFF_BYTES)
    val reader = StrictCborReader(bytes.copyOf())
    val fields = reader.readMapLength()
    require(fields in 6..7)
    reader.expectUnsignedKey(1)
    require(reader.readUnsigned() == 1L)
    reader.expectUnsignedKey(2)
    val eventId = ByteString32(reader.readByteString(32))
    reader.expectUnsignedKey(3)
    val chainId = reader.readProtocolUInt("chainId").value
    reader.expectUnsignedKey(4)
    val eventRegistry = Address20(reader.readByteString(20))
    reader.expectUnsignedKey(5)
    val definitionRegistry = Address20(reader.readByteString(20))
    reader.expectUnsignedKey(6)
    val digest = ByteString32(reader.readByteString(32))
    val url = if (fields == 7) {
        reader.expectUnsignedKey(7)
        reader.readText(2048).also { require(isAbsoluteVenueUri(it)) }
    } else null
    reader.requireFinished()
    VenueHandoff(eventId, chainId, eventRegistry, definitionRegistry, digest, url)
} catch (_: IllegalArgumentException) {
    null
}

/** Decodes the same handoff from the base64url fragment of a link or QR link. */
@OptIn(ExperimentalEncodingApi::class)
public fun decodeVenueHandoffLink(link: String): VenueHandoff? = try {
    require(link.length <= 8192)
    val delimiter = link.indexOf('#')
    require(delimiter > 0 && isAbsoluteVenueUri(link.substring(0, delimiter)))
    val fragment = link.substring(delimiter + 1)
    require(fragment.length <= 5464 && BASE64URL.matches(fragment))
    val padded = fragment.padEnd((fragment.length + 3) / 4 * 4, '=')
    decodeVenueHandoff(Base64.UrlSafe.decode(padded))
} catch (_: IllegalArgumentException) {
    null
}

/** URI syntax only. Fetching separately enforces the permitted transport and endpoint policy. */
private fun isAbsoluteVenueUri(value: String): Boolean {
    val colon = value.indexOf(':')
    if (colon <= 0 || !URI_SCHEME.matches(value.substring(0, colon))) return false
    if (value.any { it.code <= 32 || it.code >= 127 || it in "\"<>\\^`{|}" }) return false
    var index = colon + 1
    while (index < value.length) {
        if (value[index] == '%') {
            if (index + 2 >= value.length || value[index + 1].digitToIntOrNull(16) == null ||
                value[index + 2].digitToIntOrNull(16) == null) return false
            index += 2
        }
        index++
    }
    return true
}

/** Acquisition ceilings shared with native readers; checked again during decode. */
public const val MAX_VENUE_BUNDLE_BYTES: Int = 1_048_576
public const val MAX_VENUE_HANDOFF_BYTES: Int = 4096
private const val BUNDLE_DIGEST_DOMAIN: String = "levarac:venue-bundle-digest:v1\u0000"
private val URI_SCHEME = Regex("[A-Za-z][A-Za-z0-9+.-]*")
private val BASE64URL = Regex("[A-Za-z0-9_-]+={0,2}")
