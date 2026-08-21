package org.levarac.parallax.observation

/**
 * Minimal pure-Kotlin secp256k1 verifier used only at the signing boundary.
 * The private key never enters this module; native code supplies compact r || s.
 */
internal object Secp256k1 {
    private val fieldPrime = hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F")
    private val groupOrder = hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
    private val groupOrderHalf = hex("7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0")
    private val generator = Point(
        x = hex("79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"),
        y = hex("483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8"),
        z = U256.ONE,
        infinity = false,
    )
    private val fieldSquareRootExponent = hex("3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFF0C")
    private val fieldInverseExponent = hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2D")
    private val orderInverseExponent = hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD036413F")

    internal fun isValidCompressedPublicKey(publicKey: ByteArray): Boolean {
        return try {
        if (publicKey.size != 33) return false
        val prefix = publicKey[0].toInt() and 0xff
        (prefix == 2 || prefix == 3) && decodeCompressedPublicKey(publicKey, prefix) != null
    } catch (_: Throwable) {
        false
    }
    }

    internal fun verify(
        digest: ByteArray,
        signature: CompactEs256kSignature,
        publicKey: ByteArray,
    ): Boolean {
        return try {
        if (digest.size != 32 || publicKey.size != 33) return false
        val keyPrefix = publicKey[0].toInt() and 0xff
        if (keyPrefix != 2 && keyPrefix != 3) return false

        val r = U256.fromBytes(signature.r.toByteArray())
        val s = U256.fromBytes(signature.s.toByteArray())
        if (r.isZero() || r >= groupOrder || s.isZero() || s >= groupOrder) return false
        if (s > groupOrderHalf) return false

        val key = decodeCompressedPublicKey(publicKey, keyPrefix) ?: return false
        val z = U256.fromBytes(digest).let { if (it >= groupOrder) it - groupOrder else it }
        val w = modPow(s, orderInverseExponent, groupOrder)
        val u1 = modMultiply(z, w, groupOrder)
        val u2 = modMultiply(r, w, groupOrder)
        val point = add(scalarMultiply(generator, u1), scalarMultiply(key, u2))
        if (point.infinity) return false
        val affine = toAffine(point) ?: return false
        val x = if (affine.x >= groupOrder) affine.x - groupOrder else affine.x
        x == r
    } catch (_: Throwable) {
        false
    }
    }

    private fun decodeCompressedPublicKey(bytes: ByteArray, prefix: Int): Point? {
        val x = U256.fromBytes(bytes.copyOfRange(1, 33))
        if (x >= fieldPrime) return null
        val xSquared = modMultiply(x, x, fieldPrime)
        val xCubed = modMultiply(xSquared, x, fieldPrime)
        val alpha = modAdd(xCubed, U256.fromLong(7), fieldPrime)
        var y = modPow(alpha, fieldSquareRootExponent, fieldPrime)
        if (modMultiply(y, y, fieldPrime) != alpha) return null
        if (y.isOdd() != (prefix == 3)) y = fieldPrime - y
        return Point(x, y, U256.ONE, infinity = false)
    }

    private fun scalarMultiply(point: Point, scalar: U256): Point {
        var result = Point.INFINITY
        for (bit in 255 downTo 0) {
            result = double(result)
            if (scalar.bitAt(bit)) result = add(result, point)
        }
        return result
    }

    private fun double(point: Point): Point {
        if (point.infinity || point.y.isZero()) return Point.INFINITY
        val a = modMultiply(point.x, point.x, fieldPrime)
        val b = modMultiply(point.y, point.y, fieldPrime)
        val c = modMultiply(b, b, fieldPrime)
        val xPlusB = modAdd(point.x, b, fieldPrime)
        var d = modSubtract(modSubtract(modMultiply(xPlusB, xPlusB, fieldPrime), a, fieldPrime), c, fieldPrime)
        d = modAdd(d, d, fieldPrime)
        val e = modAdd(modAdd(a, a, fieldPrime), a, fieldPrime)
        val f = modMultiply(e, e, fieldPrime)
        val x = modSubtract(f, modAdd(d, d, fieldPrime), fieldPrime)
        val y = modSubtract(
            modMultiply(e, modSubtract(d, x, fieldPrime), fieldPrime),
            multiplyBySmall(c, 8, fieldPrime),
            fieldPrime,
        )
        val z = multiplyBySmall(modMultiply(point.y, point.z, fieldPrime), 2, fieldPrime)
        return Point(x, y, z, infinity = false)
    }

    private fun add(first: Point, second: Point): Point {
        if (first.infinity) return second
        if (second.infinity) return first
        val z1Squared = modMultiply(first.z, first.z, fieldPrime)
        val z2Squared = modMultiply(second.z, second.z, fieldPrime)
        val u1 = modMultiply(first.x, z2Squared, fieldPrime)
        val u2 = modMultiply(second.x, z1Squared, fieldPrime)
        val s1 = modMultiply(first.y, modMultiply(second.z, z2Squared, fieldPrime), fieldPrime)
        val s2 = modMultiply(second.y, modMultiply(first.z, z1Squared, fieldPrime), fieldPrime)
        val h = modSubtract(u2, u1, fieldPrime)
        val r = modSubtract(s2, s1, fieldPrime)
        if (h.isZero()) return if (r.isZero()) double(first) else Point.INFINITY

        val i = modMultiply(multiplyBySmall(h, 2, fieldPrime), multiplyBySmall(h, 2, fieldPrime), fieldPrime)
        val j = modMultiply(h, i, fieldPrime)
        val doubledR = multiplyBySmall(r, 2, fieldPrime)
        val v = modMultiply(u1, i, fieldPrime)
        val x = modSubtract(
            modSubtract(modMultiply(doubledR, doubledR, fieldPrime), j, fieldPrime),
            multiplyBySmall(v, 2, fieldPrime),
            fieldPrime,
        )
        val y = modSubtract(
            modMultiply(doubledR, modSubtract(v, x, fieldPrime), fieldPrime),
            multiplyBySmall(modMultiply(s1, j, fieldPrime), 2, fieldPrime),
            fieldPrime,
        )
        val z = modMultiply(
            modSubtract(
                modSubtract(
                    modMultiply(modAdd(first.z, second.z, fieldPrime), modAdd(first.z, second.z, fieldPrime), fieldPrime),
                    z1Squared,
                    fieldPrime,
                ),
                z2Squared,
                fieldPrime,
            ),
            h,
            fieldPrime,
        )
        return Point(x, y, z, infinity = false)
    }

    private fun toAffine(point: Point): Point? {
        if (point.infinity) return null
        val inverse = modPow(point.z, fieldInverseExponent, fieldPrime)
        val inverseSquared = modMultiply(inverse, inverse, fieldPrime)
        val inverseCubed = modMultiply(inverseSquared, inverse, fieldPrime)
        return Point(
            x = modMultiply(point.x, inverseSquared, fieldPrime),
            y = modMultiply(point.y, inverseCubed, fieldPrime),
            z = U256.ONE,
            infinity = false,
        )
    }

    private fun modPow(base: U256, exponent: U256, modulus: U256): U256 {
        var result = U256.ONE
        for (bit in 255 downTo 0) {
            result = modMultiply(result, result, modulus)
            if (exponent.bitAt(bit)) result = modMultiply(result, base, modulus)
        }
        return result
    }

    private fun modMultiply(left: U256, right: U256, modulus: U256): U256 {
        var result = U256.ZERO
        var addend = left
        for (bit in 0 until 256) {
            if (right.bitAt(bit)) result = modAdd(result, addend, modulus)
            addend = modAdd(addend, addend, modulus)
        }
        return result
    }

    private fun multiplyBySmall(value: U256, factor: Int, modulus: U256): U256 {
        var result = U256.ZERO
        repeat(factor) { result = modAdd(result, value, modulus) }
        return result
    }

    private fun modAdd(left: U256, right: U256, modulus: U256): U256 {
        require(left < modulus && right < modulus)
        val threshold = modulus - right
        return if (left >= threshold) left - threshold else left.addWithoutOverflow(right)
    }

    private fun modSubtract(left: U256, right: U256, modulus: U256): U256 {
        require(left < modulus && right < modulus)
        return if (left >= right) left - right else modulus - (right - left)
    }

    private data class Point(
        val x: U256,
        val y: U256,
        val z: U256,
        val infinity: Boolean,
    ) {
        companion object {
            val INFINITY = Point(U256.ZERO, U256.ZERO, U256.ZERO, infinity = true)
        }
    }

    private class U256 private constructor(private val limbs: IntArray) : Comparable<U256> {
        override fun compareTo(other: U256): Int {
            for (index in limbs.lastIndex downTo 0) {
                if (limbs[index] != other.limbs[index]) return limbs[index] - other.limbs[index]
            }
            return 0
        }

        operator fun minus(other: U256): U256 {
            require(this >= other)
            val result = IntArray(LIMB_COUNT)
            var borrow = 0
            for (index in 0 until LIMB_COUNT) {
                var difference = limbs[index] - other.limbs[index] - borrow
                if (difference < 0) {
                    difference += LIMB_BASE
                    borrow = 1
                } else {
                    borrow = 0
                }
                result[index] = difference
            }
            return U256(result)
        }

        fun addWithoutOverflow(other: U256): U256 {
            val result = IntArray(LIMB_COUNT)
            var carry = 0L
            for (index in 0 until LIMB_COUNT) {
                val sum = limbs[index].toLong() + other.limbs[index].toLong() + carry
                result[index] = (sum and LIMB_MASK.toLong()).toInt()
                carry = sum ushr LIMB_BITS
            }
            require(carry == 0L)
            return U256(result)
        }

        fun bitAt(index: Int): Boolean =
            ((limbs[index / LIMB_BITS] ushr (index % LIMB_BITS)) and 1) != 0

        fun isZero(): Boolean = limbs.all { it == 0 }

        fun isOdd(): Boolean = (limbs[0] and 1) != 0

        override fun equals(other: Any?): Boolean =
            other is U256 && limbs.contentEquals(other.limbs)

        override fun hashCode(): Int = limbs.contentHashCode()

        companion object {
            val ZERO = U256(IntArray(LIMB_COUNT))
            val ONE = fromLong(1)

            fun fromLong(value: Long): U256 {
                require(value >= 0)
                val result = IntArray(LIMB_COUNT)
                var remaining = value
                var index = 0
                while (remaining != 0L) {
                    result[index++] = (remaining and LIMB_MASK.toLong()).toInt()
                    remaining = remaining ushr LIMB_BITS
                }
                return U256(result)
            }

            fun fromBytes(bytes: ByteArray): U256 {
                require(bytes.size == 32)
                val result = IntArray(LIMB_COUNT)
                for (index in bytes.indices) {
                    val limb = (bytes.size - 1 - index) / 2
                    val unsigned = bytes[index].toInt() and 0xff
                    if ((index and 1) == 0) {
                        result[limb] = unsigned shl 8
                    } else {
                        result[limb] = result[limb] or unsigned
                    }
                }
                return U256(result)
            }
        }

        fun toByteArray(): ByteArray {
            val result = ByteArray(32)
            for (index in result.indices) {
                val limb = (result.size - 1 - index) / 2
                result[index] = if ((index and 1) == 0) {
                    (limbs[limb] ushr 8).toByte()
                } else {
                    limbs[limb].toByte()
                }
            }
            return result
        }
    }

    private fun hex(value: String): U256 {
        require(value.length == 64)
        return U256.fromBytes(ByteArray(32) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        })
    }

    private const val LIMB_COUNT: Int = 16
    private const val LIMB_BITS: Int = 16
    private const val LIMB_BASE: Int = 1 shl LIMB_BITS
    private const val LIMB_MASK: Int = LIMB_BASE - 1
}
