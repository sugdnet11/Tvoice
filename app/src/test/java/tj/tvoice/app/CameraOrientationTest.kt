package tj.tvoice.app

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraOrientationTest {
    @Test fun backCameraSubtractsDisplayRotation() {
        assertEquals(90, CameraOrientation.outputRotation(90, 0, false))
        assertEquals(0, CameraOrientation.outputRotation(90, 90, false))
        assertEquals(270, CameraOrientation.outputRotation(90, 180, false))
    }

    @Test fun frontCameraAddsDisplayRotationWithoutMirroringRemoteVideo() {
        assertEquals(90, CameraOrientation.outputRotation(90, 0, true))
        assertEquals(180, CameraOrientation.outputRotation(90, 90, true))
        assertEquals(270, CameraOrientation.outputRotation(90, 180, true))
    }

    @Test fun valuesAreNormalized() {
        assertEquals(180, CameraOrientation.outputRotation(270, 270, true))
        assertEquals(180, CameraOrientation.outputRotation(90, 270, false))
    }
}
