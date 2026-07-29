package tj.tvoice.app

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class CallDurationFormatterTest {
    @Test
    fun formatsMinutesAndHours() {
        assertEquals("00:00", CallDurationFormatter.format(0, Locale.US))
        assertEquals("02:05", CallDurationFormatter.format(125, Locale.US))
        assertEquals("1:01:01", CallDurationFormatter.format(3_661, Locale.US))
    }

    @Test
    fun clampsNegativeDuration() {
        assertEquals("00:00", CallDurationFormatter.format(-3, Locale.US))
    }
}
