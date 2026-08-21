package org.levarac.parallax.registry

/** Small commonMain SHA-256 implementation so both platform decoders hash identical bytes. */
internal object Sha256 {
    internal fun digest(input: ByteArray): ByteArray {
        require(input.size <= MAX_INPUT_BYTES) { "SHA-256 input exceeds the configured limit" }
        val paddedLength = ((input.size + 9 + 63) / 64) * 64
        val padded = ByteArray(paddedLength)
        input.copyInto(padded)
        padded[input.size] = 0x80.toByte()
        val bitLength = input.size.toLong() * 8L
        for (index in 0 until 8) {
            padded[padded.size - 1 - index] = (bitLength ushr (index * 8)).toByte()
        }

        val state = INITIAL_STATE.copyOf()
        val schedule = IntArray(64)
        var offset = 0
        while (offset < padded.size) {
            for (index in 0 until 16) {
                val base = offset + index * 4
                schedule[index] =
                    ((padded[base].toInt() and 0xff) shl 24) or
                        ((padded[base + 1].toInt() and 0xff) shl 16) or
                        ((padded[base + 2].toInt() and 0xff) shl 8) or
                        (padded[base + 3].toInt() and 0xff)
            }
            for (index in 16 until 64) {
                val value = schedule[index - 15]
                val value2 = schedule[index - 2]
                schedule[index] = smallSigma1(value2) + schedule[index - 7] + smallSigma0(value) + schedule[index - 16]
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]
            for (index in 0 until 64) {
                val t1 = h + bigSigma1(e) + choose(e, f, g) + ROUND_CONSTANTS[index] + schedule[index]
                val t2 = bigSigma0(a) + majority(a, b, c)
                h = g
                g = f
                f = e
                e = d + t1
                d = c
                c = b
                b = a
                a = t1 + t2
            }
            state[0] += a
            state[1] += b
            state[2] += c
            state[3] += d
            state[4] += e
            state[5] += f
            state[6] += g
            state[7] += h
            offset += 64
        }

        return ByteArray(32).also { output ->
            state.forEachIndexed { index, value ->
                val base = index * 4
                output[base] = (value ushr 24).toByte()
                output[base + 1] = (value ushr 16).toByte()
                output[base + 2] = (value ushr 8).toByte()
                output[base + 3] = value.toByte()
            }
        }
    }

    private fun choose(x: Int, y: Int, z: Int): Int = (x and y) xor (x.inv() and z)

    private fun majority(x: Int, y: Int, z: Int): Int = (x and y) xor (x and z) xor (y and z)

    private fun bigSigma0(value: Int): Int = value.rotateRight(2) xor value.rotateRight(13) xor value.rotateRight(22)

    private fun bigSigma1(value: Int): Int = value.rotateRight(6) xor value.rotateRight(11) xor value.rotateRight(25)

    private fun smallSigma0(value: Int): Int = value.rotateRight(7) xor value.rotateRight(18) xor (value ushr 3)

    private fun smallSigma1(value: Int): Int = value.rotateRight(17) xor value.rotateRight(19) xor (value ushr 10)

    private const val MAX_INPUT_BYTES: Int = 512 * 1_024

    private val INITIAL_STATE = intArrayOf(
        0x6a09e667,
        0xbb67ae85.toInt(),
        0x3c6ef372,
        0xa54ff53a.toInt(),
        0x510e527f,
        0x9b05688c.toInt(),
        0x1f83d9ab,
        0x5be0cd19,
    )

    private val ROUND_CONSTANTS = intArrayOf(
        0x428a2f98.toInt(), 0x71374491, 0xb5c0fbcf.toInt(), 0xe9b5dba5.toInt(),
        0x3956c25b, 0x59f111f1, 0x923f82a4.toInt(), 0xab1c5ed5.toInt(),
        0xd807aa98.toInt(), 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe.toInt(), 0x9bdc06a7.toInt(), 0xc19bf174.toInt(),
        0xe49b69c1.toInt(), 0xefbe4786.toInt(), 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152.toInt(),
        0xa831c66d.toInt(), 0xb00327c8.toInt(), 0xbf597fc7.toInt(), 0xc6e00bf3.toInt(),
        0xd5a79147.toInt(), 0x06ca6351, 0x14292967, 0x27b70a85,
        0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb,
        0x81c2c92e.toInt(), 0x92722c85.toInt(), 0xa2bfe8a1.toInt(), 0xa81a664b.toInt(),
        0xc24b8b70.toInt(), 0xc76c51a3.toInt(), 0xd192e819.toInt(), 0xd6990624.toInt(),
        0xf40e3585.toInt(), 0x106aa070, 0x19a4c116, 0x1e376c08,
        0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f,
        0x84c87814.toInt(), 0x8cc70208.toInt(), 0x90befffa.toInt(), 0xa4506ceb.toInt(),
        0xbef9a3f7.toInt(), 0xc67178f2.toInt(),
    )
}
