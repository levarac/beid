package org.levarac.parallax.registry

/** Minimal legacy Keccak-256 implementation used for the Ethereum event-id preimage. */
internal object Keccak256 {
    private const val RATE_BYTES: Int = 136
    private val roundConstants = arrayOf(
        "0000000000000001",
        "0000000000008082",
        "800000000000808a",
        "8000000080008000",
        "000000000000808b",
        "0000000080000001",
        "8000000080008081",
        "8000000000008009",
        "000000000000008a",
        "0000000000000088",
        "0000000080008009",
        "000000008000000a",
        "000000008000808b",
        "800000000000008b",
        "8000000000008089",
        "8000000000008003",
        "8000000000008002",
        "8000000000000080",
        "000000000000800a",
        "800000008000000a",
        "8000000080008081",
        "8000000000008080",
        "0000000080000001",
        "8000000080008008",
    ).map(::hexLong)

    // Indexed as x + 5*y, matching the Keccak state lane layout.
    private val rotationOffsets = intArrayOf(
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14,
    )

    internal fun digest(input: ByteArray): ByteArray {
        val state = LongArray(25)
        var offset = 0
        while (offset + RATE_BYTES <= input.size) {
            absorb(state, input, offset)
            keccakF1600(state)
            offset += RATE_BYTES
        }

        val finalBlock = ByteArray(RATE_BYTES)
        input.copyInto(finalBlock, destinationOffset = 0, startIndex = offset)
        finalBlock[input.size - offset] = 0x01
        finalBlock[RATE_BYTES - 1] = (finalBlock[RATE_BYTES - 1].toInt() or 0x80).toByte()
        absorb(state, finalBlock, 0)
        keccakF1600(state)

        val output = ByteArray(32)
        for (index in output.indices) {
            output[index] = (state[index / 8] ushr ((index % 8) * 8)).toByte()
        }
        return output
    }

    private fun absorb(state: LongArray, block: ByteArray, offset: Int) {
        for (index in 0 until RATE_BYTES) {
            val lane = index / 8
            val shift = (index % 8) * 8
            state[lane] = state[lane] xor ((block[offset + index].toLong() and 0xffL) shl shift)
        }
    }

    private fun keccakF1600(state: LongArray) {
        val columnParity = LongArray(5)
        val temporary = LongArray(25)
        repeat(24) { round ->
            for (x in 0 until 5) {
                columnParity[x] = state[x] xor state[x + 5] xor state[x + 10] xor state[x + 15] xor state[x + 20]
            }
            for (x in 0 until 5) {
                val correction = columnParity[(x + 4) % 5] xor rotateLeft(columnParity[(x + 1) % 5], 1)
                for (y in 0 until 5) state[x + 5 * y] = state[x + 5 * y] xor correction
            }

            for (x in 0 until 5) {
                for (y in 0 until 5) {
                    val destinationX = y
                    val destinationY = (2 * x + 3 * y) % 5
                    temporary[destinationX + 5 * destinationY] =
                        rotateLeft(state[x + 5 * y], rotationOffsets[x + 5 * y])
                }
            }

            for (x in 0 until 5) {
                for (y in 0 until 5) {
                    val current = temporary[x + 5 * y]
                    val next = temporary[((x + 1) % 5) + 5 * y]
                    val afterNext = temporary[((x + 2) % 5) + 5 * y]
                    state[x + 5 * y] = current xor (next.inv() and afterNext)
                }
            }
            state[0] = state[0] xor roundConstants[round]
        }
    }

    private fun rotateLeft(value: Long, distance: Int): Long {
        if (distance == 0) return value
        return (value shl distance) or (value ushr (64 - distance))
    }

    private fun hexLong(value: String): Long = value.toULong(16).toLong()
}
