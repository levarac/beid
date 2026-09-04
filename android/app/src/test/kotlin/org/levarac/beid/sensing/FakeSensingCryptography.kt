package org.levarac.beid.sensing

import java.io.File

/**
 * Fast test double for coordinator behavior tests that do not own
 * secp256k1 correctness — mirrors iOS's `DeterministicSensingCryptography`
 * (`ios/BeidTests/Support/DeterministicSensingCryptography.swift`). Golden-
 * vector correctness of the real thing lives in [OwnerKeyProviderTest]/
 * [BindingMessageTest]/[SelfProofMessageLayoutTest]/
 * [BarnardSensingCryptographyTest].
 */
internal open class FakeSensingCryptography(
    private val eventSigningPublicKeyResult: ByteArray = byteArrayOf(0x02) + ByteArray(32) { 0x33.toByte() },
    private val ownerPublicKeyResult: ByteArray = byteArrayOf(0x03) + ByteArray(32) { 0x44.toByte() },
    private val signWindowReportResult: SensingRecoverableSignature = SensingRecoverableSignature(
        r = ByteArray(32) { 0x11.toByte() },
        s = ByteArray(32) { 0x22.toByte() },
        v = 0,
    ),
    private val selfProofSignatureResult: SensingRecoverableSignature? = SensingRecoverableSignature(
        r = ByteArray(32) { 0x55.toByte() },
        s = ByteArray(32) { 0x66.toByte() },
        v = 1,
    ),
    private val walletAcknowledgementSignatureResult: SensingRecoverableSignature? = SensingRecoverableSignature(
        r = ByteArray(32) { 0x77.toByte() },
        s = ByteArray(32) { 0x88.toByte() },
        v = 0,
    ),
    private val buildAccountBindingTextResult: ((String, ByteArray, ByteArray, Long, ByteArray, String) -> String?)? = null,
) : SensingCryptography {
    sealed class Call {
        data class EventSigningPublicKey(val eventCode: String) : Call()
        data object OwnerPublicKey : Call()
        data class SignWindowReport(val eventCode: String, val bytes: ByteArray) : Call()
        data class SignSelfProof(
            val eventIdHash: ByteArray,
            val eventSigningPublicKey: ByteArray,
            val eninStart: Long,
            val eninEnd: Long,
        ) : Call()
        data class SignWalletAcknowledgement(val walletAddress: ByteArray, val walletSignature: ByteArray) : Call()
        data class BuildAccountBindingText(
            val domain: String,
            val walletAddress: ByteArray,
            val ownerPublicKey: ByteArray,
            val chainId: Long,
            val nonce: ByteArray,
            val issuedAt: String,
        ) : Call()
    }

    val calls = mutableListOf<Call>()

    override fun eventSigningPublicKey(eventCode: String): ByteArray {
        calls += Call.EventSigningPublicKey(eventCode)
        return eventSigningPublicKeyResult
    }

    override fun ownerPublicKey(): ByteArray {
        calls += Call.OwnerPublicKey
        return ownerPublicKeyResult
    }

    override open fun signWindowReport(eventCode: String, bytes: ByteArray): SensingRecoverableSignature {
        calls += Call.SignWindowReport(eventCode, bytes)
        return signWindowReportResult
    }

    override fun signSelfProof(
        eventIdHash: ByteArray,
        eventSigningPublicKey: ByteArray,
        eninStart: Long,
        eninEnd: Long,
    ): SensingRecoverableSignature? {
        calls += Call.SignSelfProof(eventIdHash, eventSigningPublicKey, eninStart, eninEnd)
        return selfProofSignatureResult
    }

    override fun signWalletAcknowledgement(
        walletAddress: ByteArray,
        walletSignature: ByteArray,
    ): SensingRecoverableSignature? {
        calls += Call.SignWalletAcknowledgement(walletAddress, walletSignature)
        return walletAcknowledgementSignatureResult
    }

    override fun buildAccountBindingText(
        domain: String,
        walletAddress: ByteArray,
        ownerPublicKey: ByteArray,
        chainId: Long,
        nonce: ByteArray,
        issuedAt: String,
    ): String? {
        calls += Call.BuildAccountBindingText(domain, walletAddress, ownerPublicKey, chainId, nonce, issuedAt)
        return buildAccountBindingTextResult?.invoke(domain, walletAddress, ownerPublicKey, chainId, nonce, issuedAt)
            ?: "$domain fake-binding-text"
    }
}

/** A fresh, empty temp file for a record store under test — deleted on JVM exit. */
internal fun newTempRecordFile(prefix: String): File =
    File.createTempFile(prefix, ".json").apply {
        delete()
        deleteOnExit()
    }
