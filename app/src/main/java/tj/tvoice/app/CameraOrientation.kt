package tj.tvoice.app

/** Camera2 rotation math kept independent from Android UI so it can be unit-tested. */
internal object CameraOrientation {
    fun outputRotation(sensorOrientation: Int, displayRotation: Int, frontFacing: Boolean): Int {
        val sensor = normalize(sensorOrientation)
        val display = normalize(displayRotation)
        return if (frontFacing) normalize(sensor + display) else normalize(sensor - display)
    }

    private fun normalize(value: Int): Int = ((value % 360) + 360) % 360
}
