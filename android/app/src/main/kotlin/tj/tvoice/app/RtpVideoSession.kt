package tj.tvoice.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** Native Camera2/MediaCodec H.264 endpoint with RFC 6184 RTP packetization. */
internal class RtpVideoSession(
    context: Context,
    private val errorListener: (String) -> Unit = {},
    private val remoteRotationListener: (Int) -> Unit = {},
    private val localRotationListener: (Int) -> Unit = {}
) {
    private val appContext = context.applicationContext
    private val socket = DatagramSocket(0).apply { soTimeout = 500 }
    private val cameraManager = appContext.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val cameraThread = HandlerThread("Tvoice-Camera").apply { start() }
    private val cameraHandler = Handler(cameraThread.looper)
    private val codecThread = HandlerThread("Tvoice-Video-Codec").apply { start() }
    private val codecHandler = Handler(codecThread.looper)
    private val running = AtomicBoolean(false)
    private val cameraEnabled = AtomicBoolean(
        appContext.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    )
    private val sequence = AtomicInteger(ThreadLocalRandom.current().nextInt(0, 65536))
    private val fallbackTimestamp = AtomicLong(ThreadLocalRandom.current().nextLong(0, 0xffffffffL))
    private val acceptedRemoteSsrc = AtomicLong(UNSET_SSRC)
    private val ssrc = ThreadLocalRandom.current().nextInt()
    private val decoderLock = Any()

    @Volatile private var remote: RemoteVideoMedia? = null
    @Volatile private var encoder: MediaCodec? = null
    @Volatile private var encoderInputSurface: Surface? = null
    @Volatile private var camera: CameraDevice? = null
    @Volatile private var captureSession: CameraCaptureSession? = null
    @Volatile private var selectedCameraId: String? = null
    @Volatile private var localPreviewSurface: Surface? = null
    @Volatile private var remoteRenderSurface: Surface? = null
    @Volatile private var decoder: MediaCodec? = null
    @Volatile private var decoderGeneration = 0
    @Volatile private var receiverThread: Thread? = null
    @Volatile private var encoderThread: Thread? = null
    private var cachedSps: ByteArray? = null
    private var cachedPps: ByteArray? = null
    private var outboundSps: ByteArray? = null
    private var outboundPps: ByteArray? = null
    @Volatile private var lastRemoteRotation = -1
    @Volatile private var captureRotationDegrees = 0
    @Volatile private var previewDisabledForSession = false

    val localPort: Int get() = socket.localPort
    val canCapture: Boolean
        get() = appContext.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
            runCatching { cameraManager.cameraIdList.isNotEmpty() }.getOrDefault(false)

    fun start(media: RemoteVideoMedia) {
        remote = media
        cacheParameterSets(media)
        if (!media.receivesVideo) cameraEnabled.set(false)
        if (!running.compareAndSet(false, true)) {
            acceptedRemoteSsrc.set(UNSET_SSRC)
            return
        }
        receiverThread = Thread(::receiveLoop, "Tvoice-RTP-Video-Receive").apply { start() }
        primeSymmetricRtpPath(media)
        if (canCapture && cameraEnabled.get()) {
            cameraHandler.post {
                runCatching { startEncoderAndCamera() }.onFailure {
                    cameraEnabled.set(false)
                    errorListener("Не удалось запустить кодирование H.264")
                }
            }
        }
        codecHandler.post { restartDecoder() }
    }

    /** Opens the mobile NAT mapping and satisfies Asterisk strict-RTP learning before the camera emits its first IDR. */
    private fun primeSymmetricRtpPath(media: RemoteVideoMedia) {
        repeat(8) { index ->
            codecHandler.postDelayed({
                if (running.get() && remote === media && media.receivesVideo) {
                    // H.264 filler-data NAL (type 12); decoders safely ignore it.
                    sendPacket(media, byteArrayOf(0x0c, 0x80.toByte()), fallbackTimestamp.get(), marker = false)
                }
            }, index * 40L)
        }
    }

    fun updateRemote(media: RemoteVideoMedia) {
        val previous = remote
        remote = media
        cacheParameterSets(media)
        if (running.get()) media.parameterSets.forEach { nal -> submitNal(nal, 0) }
        if (!media.receivesVideo) {
            cameraEnabled.set(false)
            closeCamera()
        }
        if (previous?.address != media.address || previous.port != media.port || previous.payloadType != media.payloadType) {
            acceptedRemoteSsrc.set(UNSET_SSRC)
        }
    }

    fun setSurfaces(localPreview: Surface?, remoteRender: Surface?) {
        val nextLocal = localPreview?.takeIf { it.isValid }
        val nextRemote = remoteRender?.takeIf { it.isValid }
        val localChanged = localPreviewSurface != nextLocal
        val remoteChanged = remoteRenderSurface != nextRemote
        localPreviewSurface = nextLocal
        remoteRenderSurface = nextRemote
        if (localChanged) {
            previewDisabledForSession = false
            cameraHandler.post { rebuildCaptureSession() }
        }
        if (remoteChanged) codecHandler.post { restartDecoder() }
    }

    fun setCameraEnabled(enabled: Boolean): Boolean {
        if (enabled && remote?.receivesVideo == false) return false
        cameraEnabled.set(enabled)
        if (!enabled) {
            closeCamera()
            return false
        }
        cameraHandler.post {
            if (running.get()) {
                if (encoder == null) {
                    runCatching { startEncoderAndCamera() }.onFailure {
                        cameraEnabled.set(false)
                        errorListener("Не удалось запустить кодирование H.264")
                    }
                } else openSelectedCamera()
            }
        }
        return true
    }

    fun isCameraEnabled(): Boolean = cameraEnabled.get()

    fun localRotationDegrees(): Int =
        (rawCameraRotationDegrees() - captureRotationDegrees + 360) % 360

    fun isFrontCameraSelected(): Boolean = cameraTransform().second

    fun switchCamera(): Boolean {
        val ids = usableCameraIds()
        if (ids.size < 2) return false
        val current = selectedCameraId
        selectedCameraId = ids[(ids.indexOf(current).takeIf { it >= 0 } ?: 0).let { (it + 1) % ids.size }]
        cameraHandler.post {
            closeCamera()
            if (cameraEnabled.get() && running.get()) openSelectedCamera()
        }
        return true
    }

    private fun startEncoderAndCamera() {
        if (!running.get() || encoder != null || !canCapture) return
        if (selectedCameraId == null) selectedCameraId = usableCameraIds().firstOrNull()
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, VIDEO_WIDTH, VIDEO_HEIGHT).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, VIDEO_BIT_RATE)
            setInteger(MediaFormat.KEY_FRAME_RATE, VIDEO_FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, VIDEO_I_FRAME_INTERVAL)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel31)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && remote?.videoOrientationExtensionId == null) {
                // Some hardware encoders physically apply this transform. Tvoice peers
                // use RTP/CVO below, so the two mechanisms are never enabled together.
                setInteger(MediaFormat.KEY_ROTATION, rawCameraRotationDegrees())
            }
        }
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val input = codec.createInputSurface()
            encoder = codec
            encoderInputSurface = input
            codec.start()
            encoderThread = Thread({ encoderLoop(codec) }, "Tvoice-H264-Encode").apply { start() }
            openSelectedCamera()
        } catch (error: Exception) {
            runCatching { codec.release() }
            encoder = null
            encoderInputSurface = null
            throw error
        }
    }

    @SuppressLint("MissingPermission")
    private fun openSelectedCamera() {
        if (!running.get() || !cameraEnabled.get() || !canCapture || camera != null) return
        val ids = usableCameraIds()
        val cameraId = selectedCameraId?.takeIf(ids::contains) ?: ids.firstOrNull() ?: return
        selectedCameraId = cameraId
        try {
            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    if (!running.get() || !cameraEnabled.get()) {
                        device.close()
                        return
                    }
                    camera = device
                    rebuildCaptureSession()
                }

                override fun onDisconnected(device: CameraDevice) {
                    if (camera == device) camera = null
                    device.close()
                }

                override fun onError(device: CameraDevice, error: Int) {
                    if (camera == device) camera = null
                    device.close()
                    cameraEnabled.set(false)
                    errorListener("Камера недоступна (код $error)")
                }
            }, cameraHandler)
        } catch (_: SecurityException) {
            cameraEnabled.set(false)
        }
    }

    private fun rebuildCaptureSession() {
        val device = camera ?: return
        val encoded = encoderInputSurface?.takeIf { it.isValid } ?: return
        runCatching { captureSession?.close() }
        captureSession = null
        val preview = localPreviewSurface?.takeIf { it.isValid && !previewDisabledForSession }
        val targets = listOfNotNull(encoded, preview).distinct()
        runCatching {
            device.createCaptureSession(targets, object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    if (!running.get() || camera != device || !cameraEnabled.get()) {
                        session.close()
                        return
                    }
                    captureSession = session
                    val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                        targets.forEach { target -> addTarget(target) }
                        set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                        val characteristics = runCatching {
                            cameraManager.getCameraCharacteristics(checkNotNull(selectedCameraId))
                        }.getOrNull()
                        val fpsRange = characteristics
                            ?.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                            ?.filter { it.upper >= VIDEO_FRAME_RATE && it.lower <= VIDEO_FRAME_RATE }
                            ?.minByOrNull { it.upper - it.lower }
                        if (fpsRange != null) set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange)
                        val stabilizationModes = characteristics
                            ?.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
                            ?: intArrayOf()
                        if (CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON in stabilizationModes) {
                            set(
                                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON
                            )
                        }
                        val noiseReductionModes = characteristics
                            ?.get(CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES)
                            ?: intArrayOf()
                        if (CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY in noiseReductionModes) {
                            set(
                                CaptureRequest.NOISE_REDUCTION_MODE,
                                CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY
                            )
                        }
                        var appliedRotation = 0
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val desiredRotation = rawCameraRotationDegrees()
                            val rotateMode = when (desiredRotation) {
                                90 -> CaptureRequest.SCALER_ROTATE_AND_CROP_90
                                180 -> CaptureRequest.SCALER_ROTATE_AND_CROP_180
                                270 -> CaptureRequest.SCALER_ROTATE_AND_CROP_270
                                else -> CaptureRequest.SCALER_ROTATE_AND_CROP_NONE
                            }
                            val availableModes = characteristics
                                ?.get(CameraCharacteristics.SCALER_AVAILABLE_ROTATE_AND_CROP_MODES)
                                ?: intArrayOf()
                            if (rotateMode in availableModes) {
                                set(CaptureRequest.SCALER_ROTATE_AND_CROP, rotateMode)
                                appliedRotation = desiredRotation
                            }
                        }
                        captureRotationDegrees = appliedRotation
                        localRotationListener(localRotationDegrees())
                    }.build()
                    runCatching { session.setRepeatingRequest(request, null, cameraHandler) }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    session.close()
                    // Some vendors reject a camera session with encoder + preview even
                    // when both surfaces advertise 720p. Keep the outgoing video alive
                    // and retry with the encoder target only.
                    if (preview != null && !previewDisabledForSession) {
                        previewDisabledForSession = true
                        cameraHandler.post { rebuildCaptureSession() }
                    } else {
                        errorListener("Камера не поддерживает видеорежим 1280×720")
                    }
                }
            }, cameraHandler)
        }
    }

    private fun encoderLoop(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (running.get() && encoder === codec) {
            val outputIndex = runCatching { codec.dequeueOutputBuffer(info, 20_000) }.getOrDefault(MediaCodec.INFO_TRY_AGAIN_LATER)
            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                listOf("csd-0", "csd-1").forEach { key ->
                    codec.outputFormat.getByteBuffer(key)?.let { buffer ->
                        val duplicate = buffer.duplicate()
                        val data = ByteArray(duplicate.remaining())
                        duplicate.get(data)
                        sendAccessUnit(data, fallbackTimestamp.getAndAdd(3_000))
                    }
                }
                continue
            }
            if (outputIndex < 0) continue
            val output = codec.getOutputBuffer(outputIndex)
            if (output != null && info.size > 0) {
                output.position(info.offset)
                output.limit(info.offset + info.size)
                val data = ByteArray(info.size)
                output.get(data)
                val timestamp = if (info.presentationTimeUs > 0) {
                    (info.presentationTimeUs * 90L / 1_000L) and 0xffffffffL
                } else fallbackTimestamp.getAndAdd(3_000)
                sendAccessUnit(data, timestamp)
            }
            runCatching { codec.releaseOutputBuffer(outputIndex, false) }
        }
    }

    private fun sendAccessUnit(data: ByteArray, timestamp: Long) {
        val media = remote ?: return
        if (!media.receivesVideo) return
        val accessUnits = H264RtpPacketizer.splitAccessUnit(data)
        accessUnits.forEach { nal ->
            when (nalType(nal)) {
                7 -> outboundSps = nal.copyOf()
                8 -> outboundPps = nal.copyOf()
            }
        }
        val containsIdr = accessUnits.any { nalType(it) == 5 }
        val containsParameters = accessUnits.any { nalType(it) == 7 || nalType(it) == 8 }
        val nals = if (containsIdr && !containsParameters) {
            listOfNotNull(outboundSps, outboundPps) + accessUnits
        } else accessUnits
        nals.forEachIndexed { nalIndex, nal ->
            val fragments = H264RtpPacketizer.fragment(nal)
            fragments.forEach { fragment ->
                sendPacket(
                    media,
                    fragment.payload,
                    timestamp,
                    fragment.marker && nalIndex == nals.lastIndex
                )
            }
        }
    }

    private fun sendPacket(media: RemoteVideoMedia, payload: ByteArray, timestamp: Long, marker: Boolean) {
        if (!running.get()) return
        val extensionId = media.videoOrientationExtensionId
        val hasOrientation = extensionId != null && extensionId in 1..14
        val buffer = ByteBuffer.allocate((if (hasOrientation) 20 else 12) + payload.size).order(ByteOrder.BIG_ENDIAN)
        buffer.put((if (hasOrientation) 0x90 else 0x80).toByte())
        buffer.put(((if (marker) 0x80 else 0) or (media.payloadType and 0x7f)).toByte())
        buffer.putShort((sequence.getAndIncrement() and 0xffff).toShort())
        buffer.putInt((timestamp and 0xffffffffL).toInt())
        buffer.putInt(ssrc)
        if (hasOrientation) {
            buffer.putShort(0xBEDE.toShort())
            buffer.putShort(1.toShort())
            buffer.put(((extensionId!! and 0x0f) shl 4).toByte())
            buffer.put(((localRotationDegrees() / 90) and 0x03).toByte())
            buffer.putShort(0.toShort())
        }
        buffer.put(payload)
        val bytes = buffer.array()
        runCatching { socket.send(DatagramPacket(bytes, bytes.size, InetSocketAddress(media.address, media.port))) }
    }

    private fun receiveLoop() {
        val packetBytes = ByteArray(2_048)
        var fuBuffer: ByteArrayOutputStream? = null
        var fuTimestamp = -1L
        var expectedSequence = -1
        while (running.get()) {
            val packet = DatagramPacket(packetBytes, packetBytes.size)
            try {
                socket.receive(packet)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (_: Exception) {
                if (!running.get()) break
                continue
            }
            val media = remote ?: continue
            if (!media.sendsVideo) continue
            if (packet.address != media.address) continue
            val info = RtpPacketInspector.inspect(packetBytes, packet.length, media.videoOrientationExtensionId) ?: continue
            if (info.payloadType != media.payloadType) continue
            if (!acceptSsrc(info.ssrc)) continue
            info.videoOrientationDegrees?.let { rotation ->
                if (rotation != lastRemoteRotation) {
                    lastRemoteRotation = rotation
                    remoteRotationListener(rotation)
                }
            }
            val timestamp = readUnsignedInt(packetBytes, 4)
            val packetSequence = readUnsignedShort(packetBytes, 2)
            val offset = info.payloadOffset
            val nalType = packetBytes[offset].toInt() and 0x1f
            when (nalType) {
                in 1..23 -> submitNal(packetBytes.copyOfRange(offset, offset + info.payloadSize), timestamp)
                24 -> H264RtpPacketizer.unpackStapA(
                    packetBytes.copyOfRange(offset, offset + info.payloadSize)
                ).forEach { nal -> submitNal(nal, timestamp) }
                28 -> {
                    if (info.payloadSize < 3) continue
                    val fuHeader = packetBytes[offset + 1].toInt() and 0xff
                    val start = fuHeader and 0x80 != 0
                    val end = fuHeader and 0x40 != 0
                    if (start) {
                        fuBuffer = ByteArrayOutputStream().apply {
                            write((packetBytes[offset].toInt() and 0xe0) or (fuHeader and 0x1f))
                            write(packetBytes, offset + 2, info.payloadSize - 2)
                        }
                        fuTimestamp = timestamp
                        expectedSequence = (packetSequence + 1) and 0xffff
                    } else {
                        val target = fuBuffer
                        if (target == null || timestamp != fuTimestamp || packetSequence != expectedSequence ||
                            target.size() + info.payloadSize > MAX_NAL_SIZE
                        ) {
                            fuBuffer = null
                            continue
                        }
                        target.write(packetBytes, offset + 2, info.payloadSize - 2)
                        expectedSequence = (packetSequence + 1) and 0xffff
                        if (end) {
                            submitNal(target.toByteArray(), timestamp)
                            fuBuffer = null
                        }
                    }
                }
            }
        }
    }

    private fun acceptSsrc(value: Long): Boolean {
        val accepted = acceptedRemoteSsrc.get()
        return when {
            accepted == value -> true
            accepted == UNSET_SSRC -> acceptedRemoteSsrc.compareAndSet(UNSET_SSRC, value) || acceptedRemoteSsrc.get() == value
            else -> false
        }
    }

    private fun cacheParameterSets(media: RemoteVideoMedia) {
        media.parameterSets.forEach { nal ->
            when (nalType(nal)) {
                7 -> cachedSps = nal.copyOf()
                8 -> cachedPps = nal.copyOf()
            }
        }
    }

    private fun submitNal(nal: ByteArray, timestamp: Long) {
        if (nal.isEmpty() || nal.size > MAX_NAL_SIZE) return
        when (nal[0].toInt() and 0x1f) {
            7 -> cachedSps = nal.copyOf()
            8 -> cachedPps = nal.copyOf()
        }
        synchronized(decoderLock) {
            val codec = decoder ?: return
            val inputIndex = runCatching { codec.dequeueInputBuffer(5_000) }.getOrDefault(-1)
            if (inputIndex < 0) return
            val input = codec.getInputBuffer(inputIndex) ?: return
            input.clear()
            if (input.remaining() < nal.size + 4) {
                codec.queueInputBuffer(inputIndex, 0, 0, timestamp * 1_000L / 90L, 0)
                return
            }
            input.put(byteArrayOf(0, 0, 0, 1))
            input.put(nal)
            codec.queueInputBuffer(inputIndex, 0, nal.size + 4, timestamp * 1_000L / 90L, 0)
        }
    }

    private fun restartDecoder() {
        synchronized(decoderLock) {
            decoderGeneration += 1
            val old = decoder
            decoder = null
            runCatching { old?.stop() }
            runCatching { old?.release() }
            val surface = remoteRenderSurface?.takeIf { it.isValid } ?: return
            if (!running.get()) return
            val codec = runCatching { MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC) }.getOrNull() ?: return
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, VIDEO_WIDTH, VIDEO_HEIGHT)
            try {
                codec.configure(format, surface, null, 0)
                codec.start()
                codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING)
                decoder = codec
                cachedSps?.let { submitNal(it, 0) }
                cachedPps?.let { submitNal(it, 0) }
                val generation = decoderGeneration
                Thread({ decoderLoop(codec, generation) }, "Tvoice-H264-Decode").start()
            } catch (_: Exception) {
                runCatching { codec.release() }
                errorListener("Не удалось запустить декодирование H.264")
            }
        }
    }

    private fun decoderLoop(codec: MediaCodec, generation: Int) {
        val info = MediaCodec.BufferInfo()
        while (running.get() && decoder === codec && decoderGeneration == generation) {
            val index = runCatching { codec.dequeueOutputBuffer(info, 20_000) }.getOrDefault(MediaCodec.INFO_TRY_AGAIN_LATER)
            if (index >= 0) runCatching { codec.releaseOutputBuffer(index, true) }
        }
    }

    private fun usableCameraIds(): List<String> = runCatching {
        cameraManager.cameraIdList.sortedBy { id ->
            when (cameraManager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_FRONT -> 0
                CameraCharacteristics.LENS_FACING_BACK -> 1
                else -> 2
            }
        }
    }.getOrDefault(emptyList())

    @Suppress("DEPRECATION")
    private fun cameraTransform(): Pair<Int, Boolean> {
        val cameraId = selectedCameraId ?: usableCameraIds().firstOrNull() ?: return 0 to true
        val characteristics = runCatching { cameraManager.getCameraCharacteristics(cameraId) }.getOrNull()
            ?: return 0 to true
        val sensor = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val front = characteristics.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
        val rotation = (appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.rotation
        val displayDegrees = when (rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        return CameraOrientation.outputRotation(sensor, displayDegrees, front) to front
    }

    private fun rawCameraRotationDegrees(): Int = cameraTransform().first

    private fun closeCamera() {
        runCatching { captureSession?.stopRepeating() }
        runCatching { captureSession?.close() }
        runCatching { camera?.close() }
        captureSession = null
        camera = null
        captureRotationDegrees = 0
    }

    fun close() {
        if (!running.getAndSet(false)) {
            socket.close()
            cameraThread.quitSafely()
            codecThread.quitSafely()
            return
        }
        closeCamera()
        runCatching { encoder?.signalEndOfInputStream() }
        runCatching { encoder?.stop() }
        runCatching { encoder?.release() }
        runCatching { encoderInputSurface?.release() }
        encoder = null
        encoderInputSurface = null
        synchronized(decoderLock) {
            decoderGeneration += 1
            runCatching { decoder?.stop() }
            runCatching { decoder?.release() }
            decoder = null
        }
        socket.close()
        receiverThread?.interrupt()
        encoderThread?.interrupt()
        cameraThread.quitSafely()
        codecThread.quitSafely()
    }

    private fun readUnsignedShort(data: ByteArray, offset: Int): Int =
        ((data[offset].toInt() and 0xff) shl 8) or (data[offset + 1].toInt() and 0xff)

    private fun readUnsignedInt(data: ByteArray, offset: Int): Long =
        ((data[offset].toLong() and 0xff) shl 24) or
            ((data[offset + 1].toLong() and 0xff) shl 16) or
            ((data[offset + 2].toLong() and 0xff) shl 8) or
            (data[offset + 3].toLong() and 0xff)

    private fun nalType(nal: ByteArray): Int = if (nal.isEmpty()) -1 else (nal[0].toInt() and 0x1f)

    private companion object {
        const val VIDEO_WIDTH = 1280
        const val VIDEO_HEIGHT = 720
        const val VIDEO_BIT_RATE = 2_000_000
        const val VIDEO_FRAME_RATE = 24
        const val VIDEO_I_FRAME_INTERVAL = 1
        const val MAX_NAL_SIZE = 2 * 1024 * 1024
        const val UNSET_SSRC = -1L
    }
}
