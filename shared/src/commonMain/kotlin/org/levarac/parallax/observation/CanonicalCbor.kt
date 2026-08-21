package org.levarac.parallax.observation

/** Small deterministic-CBOR writer for the frozen Observation/COSE surface. */
internal object CanonicalCbor {
    internal sealed interface Value

    private data class Unsigned(val value: Long) : Value
    private data class Negative(val value: Long) : Value
    private data class Bytes(val value: ByteArray) : Value
    private data class Text(val value: String) : Value
    private data class ArrayValue(val values: List<Value>) : Value
    private data class MapValue(val values: List<Pair<Value, Value>>) : Value
    private data class Tag(val tag: Long, val value: Value) : Value
    private data object NullValue : Value

    internal fun uint(value: Long): Value {
        require(value >= 0) { "CBOR unsigned integer must be non-negative" }
        return Unsigned(value)
    }

    internal fun negative(value: Long): Value {
        require(value < 0) { "CBOR negative integer must be negative" }
        return Negative(value)
    }

    internal fun bytes(value: ByteArray): Value = Bytes(value.copyOf())

    internal fun text(value: String): Value = Text(value)

    internal fun array(vararg values: Value): Value = ArrayValue(values.toList())

    internal fun array(values: List<Value>): Value = ArrayValue(values.toList())

    internal fun map(vararg values: Pair<Value, Value>): Value = MapValue(values.toList())

    internal fun nullValue(): Value = NullValue

    internal fun encodeTag(tag: Long, value: Value): ByteArray = encode(Tag(tag, value))

    internal fun encode(value: Value): ByteArray {
        val writer = Writer()
        writer.write(value)
        return writer.toByteArray()
    }

    private class Writer {
        private val bytes = ArrayList<Byte>()

        fun write(value: Value) {
            when (value) {
                is Unsigned -> writeTypeAndLength(0, value.value)
                is Negative -> writeTypeAndLength(1, -1L - value.value)
                is Bytes -> {
                    writeTypeAndLength(2, value.value.size.toLong())
                    writeBytes(value.value)
                }
                is Text -> {
                    val encoded = value.value.encodeToByteArray()
                    writeTypeAndLength(3, encoded.size.toLong())
                    writeBytes(encoded)
                }
                is ArrayValue -> {
                    writeTypeAndLength(4, value.values.size.toLong())
                    value.values.forEach(::write)
                }
                is MapValue -> {
                    val sorted = value.values.sortedWith { left, right ->
                        compareLexicographically(encode(left.first), encode(right.first))
                    }
                    writeTypeAndLength(5, sorted.size.toLong())
                    sorted.forEach { (key, item) ->
                        write(key)
                        write(item)
                    }
                }
                is Tag -> {
                    writeTypeAndLength(6, value.tag)
                    write(value.value)
                }
                NullValue -> appendByte(0xf6)
            }
        }

        fun toByteArray(): ByteArray = bytes.toByteArray()

        private fun writeTypeAndLength(majorType: Int, length: Long) {
            require(length >= 0) { "CBOR length must be non-negative" }
            when {
                length < 24 -> appendByte((majorType shl 5) or length.toInt())
                length <= 0xff -> {
                    appendByte((majorType shl 5) or 24)
                    appendByte(length.toInt())
                }
                length <= 0xffff -> {
                    appendByte((majorType shl 5) or 25)
                    appendByte((length ushr 8).toInt())
                    appendByte(length.toInt())
                }
                length <= 0xffff_ffffL -> {
                    appendByte((majorType shl 5) or 26)
                    repeat(4) { shift ->
                        appendByte((length ushr (24 - shift * 8)).toInt())
                    }
                }
                else -> {
                    appendByte((majorType shl 5) or 27)
                    repeat(8) { shift ->
                        appendByte((length ushr (56 - shift * 8)).toInt())
                    }
                }
            }
        }

        private fun writeBytes(value: ByteArray) {
            value.forEach { appendByte(it.toInt()) }
        }

        private fun appendByte(value: Int) {
            bytes += value.toByte()
        }
    }
}

private fun compareLexicographically(left: ByteArray, right: ByteArray): Int {
    val common = minOf(left.size, right.size)
    for (index in 0 until common) {
        val l = left[index].toInt() and 0xff
        val r = right[index].toInt() and 0xff
        if (l != r) return l - r
    }
    return left.size - right.size
}
