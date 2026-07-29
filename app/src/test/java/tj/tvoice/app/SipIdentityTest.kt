package tj.tvoice.app

import org.junit.Assert.assertEquals
import org.junit.Test

class SipIdentityTest {
    @Test
    fun normalizesDeviceAndSipAddresses() {
        assertEquals("70007", SipIdentity.normalize(" 7 00-07 "))
        assertEquals("99270007", SipIdentity.normalize("+992 (700) 07"))
        assertEquals("73302", SipIdentity.normalize("sip:73302@185.177.2.115;user=phone"))
        assertEquals("alice", SipIdentity.normalize("alice@example.org"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsInvalidRecipient() {
        SipIdentity.requireValid("sip:bad recipient@example.org")
    }
}
