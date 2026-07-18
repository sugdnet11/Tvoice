package tj.tvoice.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Process
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

internal enum class AudioCodec(val payloadType: Int) {
    PCMA(8), PCMU(0)
}

internal data class RemoteMedia(
    val address: InetAddress,
    val port: Int,
    val codec: AudioCodec,
    val telephoneEventPayload: Int?
) {
    companion object {
        fun fromSdp(sdp: String, fallbackAddress: InetAddress): RemoteMedia? {
            var connectionAddress: InetAddress? = null
            var port: Int? = null
            var payloads = emptyList<Int>()
            val rtpMaps = mutableMapOf<Int, String>()

            sdp.lineSequence().map { it.trim() }.forEach { line ->
                when {
                    line.startsWith("c=IN IP4 ", true) || line.startsWith("c=IN IP6 ", true) -> {
                        val host = line.substringAfterLast(' ').trim()
                        connectionAddress = runCatching { InetAddress.getByName(host) }.getOrNull()
                    }
                    line.startsWith("m=audio ", true) -> {
                        val values = line.split(Regex("\\s+"))
                        port = values.getOrNull(1)?.toIntOrNull()
                        payloads = values.drop(3).mapNotNull { it.toIntOrNull() }
                    }
                    line.startsWith("a=rtpmap:", true) -> {
                        val payload = line.substringAfter(':').substringBefore(' ').toIntOrNull()
                        val name = line.substringAfter(' ', "").substringBefore('/').uppercase()
                        if (payload != null && name.isNotEmpty()) rtpMaps[payload] = name
                    }
                }
            }
            val remotePort = port?.takeIf { it in 1..65535 } ?: return null
            val codec = when {
                payloads.contains(8) || rtpMaps.any { (pt, name) -> pt in payloads && name == "PCMA" } -> AudioCodec.PCMA
                payloads.contains(0) || rtpMaps.any { (pt, name) -> pt in payloads && name == "PCMU" } -> AudioCodec.PCMU
                else -> return null
            }
            val telephoneEvent = rtpMaps.entries.firstOrNull { (pt, name) -> pt in payloads && name == "TELEPHONE-EVENT" }?.key
            return RemoteMedia(connectionAddress ?: fallbackAddress, remotePort, codec, telephoneEvent)
        }
    }
}

internal class RtpAudioSession(context: Context) {
    private val appContext = context.applicationContext
    private val socket = DatagramSocket(0).apply { soTimeout = 500 }
    private val running = AtomicBoolean(false)
    private val muted = AtomicBoolean(false)
    private val held = AtomicBoolean(false)
    private val sequence = AtomicInteger(ThreadLocalRandom.current().nextInt(0, 65536))
    private val timestamp = AtomicLong(ThreadLocalRandom.current().nextLong(0, 0xffffffffL))
    private val ssrc = ThreadLocalRandom.current().nextInt()
    private val sendLock = Any()
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    @Volatile private var remote: RemoteMedia? = null
    @Volatile private var audioRecord: AudioRecord? = null
    @Volatile private var audioTrack: AudioTrack? = null
    @Volatile private var captureThread: Thread? = null
    @Volatile private var playbackThread: Thread? = null
    @Volatile private var speakerEnabled = false

    val localPort: Int get() = socket.localPort

    fun start(media: RemoteMedia) {
        remote = media
        if (!running.compareAndSet(false, true)) return
        configureAudio()
        captureThread = Thread(::captureLoop, "Tvoice-RTP-Capture").apply { start() }
        playbackThread = Thread(::playbackLoop, "Tvoice-RTP-Playback").apply { start() }
    }

    fun updateRemote(media: RemoteMedia) {
        remote = media
    }

    fun setMuted(value: Boolean) {
        muted.set(value)
    }

    fun setHeld(value: Boolean) {
        held.set(value)
    }

    fun setSpeaker(value: Boolean) {
        speakerEnabled = value
        @Suppress("DEPRECATION")
        runCatching { audioManager.isSpeakerphoneOn = value }
    }

    fun sendDtmf(digit: Char): Boolean {
        val media = remote ?: return false
        val payloadType = media.telephoneEventPayload ?: return false
        val event = when (digit) {
            in '0'..'9' -> digit - '0'
            '*' -> 10
            '#' -> 11
            else -> return false
        }
        Thread({
            val eventTimestamp = timestamp.get()
            var duration = 160
            repeat(6) { index ->
                val end = index >= 3
                val payload = byteArrayOf(
                    event.toByte(),
                    ((if (end) 0x80 else 0x00) or 10).toByte(),
                    ((duration shr 8) and 0xff).toByte(),
                    (duration and 0xff).toByte()
                )
                sendPacket(media, payloadType, payload, eventTimestamp, index == 0)
                if (!end) duration += 160
                runCatching { Thread.sleep(20) }
            }
        }, "Tvoice-RTP-DTMF").start()
        return true
    }

    private fun configureAudio() {
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        setSpeaker(false)

        val inputMin = AudioRecord.getMinBufferSize(8000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            8000,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(inputMin, 160 * 2 * 8)
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IllegalStateException("Не удалось открыть микрофон")
        }
        audioRecord = record
        runCatching {
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(record.audioSessionId)?.enabled = true
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(record.audioSessionId)?.enabled = true
        }

        val outputMin = AudioTrack.getMinBufferSize(8000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(8000)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(outputMin, 160 * 2 * 10))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            record.release()
            audioRecord = null
            throw IllegalStateException("Не удалось открыть динамик")
        }
        audioTrack = track
        track.play()
        record.startRecording()
    }

    private fun captureLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val samples = ShortArray(160)
        while (running.get()) {
            val record = audioRecord ?: break
            val count = runCatching { record.read(samples, 0, samples.size, AudioRecord.READ_BLOCKING) }.getOrDefault(0)
            if (count <= 0) continue
            val media = remote ?: continue
            val payload = ByteArray(count)
            if (!muted.get() && !held.get()) {
                for (i in 0 until count) {
                    payload[i] = when (media.codec) {
                        AudioCodec.PCMA -> G711.encodeAlaw(samples[i])
                        AudioCodec.PCMU -> G711.encodeUlaw(samples[i])
                    }
                }
            } else {
                val silence = when (media.codec) {
                    AudioCodec.PCMA -> G711.encodeAlaw(0)
                    AudioCodec.PCMU -> G711.encodeUlaw(0)
                }
                payload.fill(silence)
            }
            val packetTimestamp = timestamp.getAndAdd(count.toLong()) and 0xffffffffL
            sendPacket(media, media.codec.payloadType, payload, packetTimestamp, false)
        }
    }

    private fun playbackLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val packetBytes = ByteArray(2048)
        while (running.get()) {
            val datagram = DatagramPacket(packetBytes, packetBytes.size)
            try {
                socket.receive(datagram)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (_: Exception) {
                if (!running.get()) break
                continue
            }
            if (datagram.length < 12) continue
            val version = (packetBytes[0].toInt() ushr 6) and 0x03
            if (version != 2) continue
            val csrcCount = packetBytes[0].toInt() and 0x0f
            val extension = packetBytes[0].toInt() and 0x10 != 0
            var offset = 12 + csrcCount * 4
            if (extension && datagram.length >= offset + 4) {
                val extWords = ((packetBytes[offset + 2].toInt() and 0xff) shl 8) or (packetBytes[offset + 3].toInt() and 0xff)
                offset += 4 + extWords * 4
            }
            if (offset >= datagram.length) continue
            val payloadType = packetBytes[1].toInt() and 0x7f
            val media = remote ?: continue
            if (payloadType != media.codec.payloadType) continue
            val sampleCount = datagram.length - offset
            val samples = ShortArray(sampleCount)
            for (i in 0 until sampleCount) {
                samples[i] = when (media.codec) {
                    AudioCodec.PCMA -> G711.decodeAlaw(packetBytes[offset + i])
                    AudioCodec.PCMU -> G711.decodeUlaw(packetBytes[offset + i])
                }
            }
            if (!held.get()) runCatching { audioTrack?.write(samples, 0, samples.size, AudioTrack.WRITE_BLOCKING) }
        }
    }

    private fun sendPacket(media: RemoteMedia, payloadType: Int, payload: ByteArray, packetTimestamp: Long, marker: Boolean) {
        synchronized(sendLock) {
            if (!running.get()) return
            val buffer = ByteBuffer.allocate(12 + payload.size).order(ByteOrder.BIG_ENDIAN)
            buffer.put(0x80.toByte())
            buffer.put(((if (marker) 0x80 else 0x00) or (payloadType and 0x7f)).toByte())
            buffer.putShort((sequence.getAndIncrement() and 0xffff).toShort())
            buffer.putInt((packetTimestamp and 0xffffffffL).toInt())
            buffer.putInt(ssrc)
            buffer.put(payload)
            runCatching {
                val bytes = buffer.array()
                socket.send(DatagramPacket(bytes, bytes.size, InetSocketAddress(media.address, media.port)))
            }
        }
    }

    fun close() {
        if (!running.getAndSet(false)) {
            socket.close()
            return
        }
        runCatching { audioRecord?.stop() }
        runCatching { audioTrack?.stop() }
        runCatching { audioRecord?.release() }
        runCatching { audioTrack?.release() }
        audioRecord = null
        audioTrack = null
        socket.close()
        captureThread?.interrupt()
        playbackThread?.interrupt()
        audioManager.mode = AudioManager.MODE_NORMAL
    }
}
