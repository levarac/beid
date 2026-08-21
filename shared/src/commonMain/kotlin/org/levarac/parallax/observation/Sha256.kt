package org.levarac.parallax.observation

internal object Sha256 {
    private val roundConstants = intArrayOf(
        0x428a2f98.toInt(), 0x71374491, 0xb5c0fbcf.toInt(), 0xe9b5dba5.toInt(),
        0x3956c25b, 0x59f111f1, 0x923f82a4.toInt(), 0xab1c5ed5.toInt(),
        0xd807aa98.toInt(), 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe.toInt(), 0x9bdc06a7.toInt(), 0xc19bf174.toInt(),
        0xe49b69c1.toInt(), 0xefbe4786.toInt(), 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152.toInt(), 0xa831c66d.toInt(), 0xb00327c8.toInt(), 0xbf597fc7.toInt(),
        0xc6e00bf3.toInt(), 0xd5a79147.toInt(), 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e.toInt(), 0x92722c85.toInt(),
        0xa2bfe8a1.toInt(), 0xa81a664b.toInt(), 0xc24b8b70.toInt(), 0xc76c51a3.toInt(),
        0xd192e819.toInt(), 0xd6990624.toInt(), 0xf40e3585.toInt(), 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814.toInt(), 0x8cc70208.toInt(),
        0x90befffa.toInt(), 0xa4506ceb.toInt(), 0xbef9a3f7.toInt(), 0xc67178f2.toInt(),
    )

    internal fun digest(input: ByteArray): ByteArray {
        val bitLength = input.size.toLong() * 8L
        val paddedLength = ((input.size + 9 + 63) / 64) * 64
        val padded = ByteArray(paddedLength)
        input.copyInto(padded)
        padded[input.size] = 0x80.toByte()
        for (shift in 0 until 8) {
            padded[padded.size - 1 - shift] = (bitLength ushr (shift * 8)).toByte()
        }

        var h0 = 0x6a09e667
        var h1 = 0xbb67ae85.toInt()
        var h2 = 0x3c6ef372
        var h3 = 0xa54ff53a.toInt()
        var h4 = 0x510e527f
        var h5 = 0x9b05688c.toInt()
        var h6 = 0x1f83d9ab
        var h7 = 0x5be0cd19
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
                val first = schedule[index - 15]
                val second = schedule[index - 2]
                val smallSigma0 = rotateRight(first, 7) xor rotateRight(first, 18) xor (first ushr 3)
                val smallSigma1 = rotateRight(second, 17) xor rotateRight(second, 19) xor (second ushr 10)
                schedule[index] = schedule[index - 16] + smallSigma0 + schedule[index - 7] + smallSigma1
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            var f = h5
            var g = h6
            var h = h7
            for (index in 0 until 64) {
                val bigSigma1 = rotateRight(e, 6) xor rotateRight(e, 11) xor rotateRight(e, 25)
                val choose = (e and f) xor (e.inv() and g)
                val temp1 = h + bigSigma1 + choose + roundConstants[index] + schedule[index]
                val bigSigma0 = rotateRight(a, 2) xor rotateRight(a, 13) xor rotateRight(a, 22)
                val majority = (a and b) xor (a and c) xor (b and c)
                val temp2 = bigSigma0 + majority
                h = g
                g = f
                f = e
                e = d + temp1
                d = c
                c = b
                b = a
                a = temp1 + temp2
            }
            h0 += a
            h1 += b
            h2 += c
            h3 += d
            h4 += e
            h5 += f
            h6 += g
            h7 += h
            offset += 64
        }

        return byteArrayOf(
            (h0 ushr 24).toByte(), (h0 ushr 16).toByte(), (h0 ushr 8).toByte(), h0.toByte(),
            (h1 ushr 24).toByte(), (h1 ushr 16).toByte(), (h1 ushr 8).toByte(), h1.toByte(),
            (h2 ushr 24).toByte(), (h2 ushr 16).toByte(), (h2 ushr 8).toByte(), h2.toByte(),
            (h3 ushr 24).toByte(), (h3 ushr 16).toByte(), (h3 ushr 8).toByte(), h3.toByte(),
            (h4 ushr 24).toByte(), (h4 ushr 16).toByte(), (h4 ushr 8).toByte(), h4.toByte(),
            (h5 ushr 24).toByte(), (h5 ushr 16).toByte(), (h5 ushr 8).toByte(), h5.toByte(),
            (h6 ushr 24).toByte(), (h6 ushr 16).toByte(), (h6 ushr 8).toByte(), h6.toByte(),
            (h7 ushr 24).toByte(), (h7 ushr 16).toByte(), (h7 ushr 8).toByte(), h7.toByte(),
        )
    }

    private fun rotateRight(value: Int, distance: Int): Int =
        (value ushr distance) or (value shl (32 - distance))
}
