package tj.tvoice.app

import java.util.Locale

internal object CallDurationFormatter {
    fun format(seconds: Long, locale: Locale = Locale.getDefault()): String {
        val safeSeconds = seconds.coerceAtLeast(0L)
        val hours = safeSeconds / 3_600
        val minutes = (safeSeconds % 3_600) / 60
        val remainder = safeSeconds % 60
        return if (hours > 0) {
            "%d:%02d:%02d".format(locale, hours, minutes, remainder)
        } else {
            "%02d:%02d".format(locale, minutes, remainder)
        }
    }
}
