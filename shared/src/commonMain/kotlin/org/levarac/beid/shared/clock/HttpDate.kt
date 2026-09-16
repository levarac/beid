package org.levarac.beid.shared.clock

private val MONTHS = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
private val DAY_NAMES = setOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

/**
 * Parses an RFC 9110 IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) to Unix
 * seconds. The obsolete RFC 850 and asctime forms are rejected rather than
 * guessed at: an unparsable header is a failed measurement, which the
 * preflight reports as undeterminable.
 */
public fun parseHttpDateEpochSeconds(value: String?): Long? {
    if (value == null || value.length != 29) return null
    if (value.substring(0, 3) !in DAY_NAMES) return null
    if (value[3] != ',' || value[4] != ' ' || value[7] != ' ' || value[11] != ' ' || value[16] != ' ') return null
    if (value[19] != ':' || value[22] != ':' || value[25] != ' ') return null
    if (value.substring(26) != "GMT") return null
    val day = value.digits(5, 7) ?: return null
    val month = MONTHS.indexOf(value.substring(8, 11)) + 1
    if (month == 0) return null
    val year = value.digits(12, 16) ?: return null
    val hour = value.digits(17, 19) ?: return null
    val minute = value.digits(20, 22) ?: return null
    val second = value.digits(23, 25) ?: return null
    if (day < 1 || day > daysInMonth(year, month)) return null
    if (hour > 23 || minute > 59 || second > 60) return null
    val days = daysFromCivil(year.toLong(), month, day)
    return days * 86_400L + hour * 3_600L + minute * 60L + second
}

private fun String.digits(start: Int, end: Int): Int? {
    var result = 0
    for (index in start until end) {
        val c = this[index]
        if (c < '0' || c > '9') return null
        result = result * 10 + (c - '0')
    }
    return result
}

private fun daysInMonth(year: Int, month: Int): Int = when (month) {
    2 -> if ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) 29 else 28
    4, 6, 9, 11 -> 30
    else -> 31
}

/** Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm). */
private fun daysFromCivil(year: Long, month: Int, day: Int): Long {
    val y = if (month <= 2) year - 1 else year
    val era = (if (y >= 0) y else y - 399) / 400
    val yoe = y - era * 400
    val mp = if (month > 2) month - 3 else month + 9
    val doy = (153 * mp + 2) / 5 + day - 1
    val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}
