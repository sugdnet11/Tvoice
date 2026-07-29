package tj.tvoice.app

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.os.Build
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.SocketException
import java.net.SocketTimeoutException
import android.view.Surface
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal class TvoiceSipCore(
    context: Context,
    private val listener: Listener
) {
    interface Listener {
        fun onRegistration(state: RegistrationState, message: String)
        fun onCall(state: CallState, remote: String, message: String)
        fun onMessage(state: MessageState, remote: String, text: String, message: String)
    }

    private data class Dialog(
        val direction: Direction,
        val remoteUser: String,
        val callId: String,
        val localTag: String,
        var remoteTag: String?,
        var localCseq: Int,
        val remoteCseq: Int,
        var inviteBranch: String,
        var peer: InetSocketAddress,
        var remoteTarget: String,
        var routeSet: List<String>,
        val rtp: RtpAudioSession,
        var video: RtpVideoSession?,
        var remoteMedia: RemoteMedia?,
        var remoteVideo: RemoteVideoMedia?,
        var incomingInvite: SipMessage? = null,
        var connected: Boolean = false,
        var accepted: Boolean = false,
        var held: Boolean = false,
        var pendingHold: Boolean? = null,
        var authChallenge: DigestChallenge? = null,
        var authHeaderName: String = "Authorization",
        var authAttempts: Int = 0,
        var nonceCount: Int = 0
    )

    private data class MessageTransaction(
        val remoteUser: String,
        val text: String,
        val callId: String,
        val localTag: String,
        var cseq: Int = 1,
        var branch: String,
        var challenge: DigestChallenge? = null,
        var authHeaderName: String = "Authorization",
        var authAttempts: Int = 0,
        var nonceCount: Int = 0
    )

    private enum class Direction { OUTGOING, INCOMING }

    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val server = InetSocketAddress(InetAddress.getByName(SipConfig.DOMAIN), SipConfig.PORT)
    private val sipSocket = DatagramSocket(0).apply { soTimeout = 750 }
    private val running = AtomicBoolean(true)
    private val worker = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "Tvoice-SIP-Worker").apply { isDaemon = true }
    }
    private val localAddress: InetAddress = resolveLocalAddress()
    private val receiver = Thread(::receiveLoop, "Tvoice-SIP-Receiver").apply { isDaemon = true; start() }

    private var username = ""
    private var password = ""
    private var registrationCallId = ""
    private var registrationTag = ""
    private var registrationCseq = 0
    private var registrationChallenge: DigestChallenge? = null
    private var registrationAuthHeader = "Authorization"
    private var registrationAuthAttempts = 0
    private var registrationNonceCount = 0
    private var registrationRequestedExpires = 0
    private var registrationPendingCseq: Int? = null
    private var registered = false
    private var keepAlive: ScheduledFuture<*>? = null
    private var registrationRetry: ScheduledFuture<*>? = null
    private var retryDelaySeconds = 5L
    private var mappedContact: ViaMapping? = null
    private var dialog: Dialog? = null
    private val pendingMessages = linkedMapOf<String, MessageTransaction>()
    private val receivedMessageIds = linkedSetOf<String>()
    private var muted = false
    private var speaker = false

    fun register(user: String, secret: String) {
        require(user.isNotBlank()) { "Введите SIP-номер" }
        require(secret.isNotBlank()) { "Введите пароль" }
        worker.execute {
            if (!running.get()) return@execute
            if (dialog != null) finishCall(CallState.End, "Смена аккаунта")
            if (registered && username.isNotEmpty() && username != user.trim()) {
                runCatching { sendRegister(expires = 0) }
            }
            username = user.trim()
            password = secret
            registrationCallId = "${randomHex(12)}@${localAddress.hostAddress}"
            registrationTag = randomHex(8)
            registrationCseq = 0
            registrationChallenge = null
            registrationAuthAttempts = 0
            registrationNonceCount = 0
            registered = false
            keepAlive?.cancel(false)
            registrationRetry?.cancel(false)
            retryDelaySeconds = 5L
            listener.onRegistration(RegistrationState.Progress, "Регистрация на ${SipConfig.DOMAIN}")
            runCatching { sendRegister(expires = 300) }
                .onFailure { failRegistration(it.message ?: "Ошибка сети") }
        }
    }

    fun unregister() {
        worker.execute {
            if (dialog != null) finishCall(CallState.End, "Выход из аккаунта")
            keepAlive?.cancel(false)
            registrationRetry?.cancel(false)
            if (registered && username.isNotEmpty()) runCatching { sendRegister(expires = 0) }
            registered = false
            listener.onRegistration(RegistrationState.Cleared, "Регистрация отключена")
        }
    }

    fun call(number: String) = startCall(number, withVideo = false)

    fun videoCall(number: String) = startCall(number, withVideo = true)

    private fun startCall(number: String, withVideo: Boolean) {
        require(number.isNotBlank()) { "Введите номер" }
        worker.execute {
            if (!registered) {
                listener.onCall(CallState.Error, number, "Сначала подключите SIP-аккаунт")
                return@execute
            }
            if (dialog != null) {
                listener.onCall(CallState.Error, number, "Другой звонок уже активен")
                return@execute
            }
            if (withVideo) speaker = shouldUseSpeakerForVideo()
            val session = RtpAudioSession(appContext)
            val videoSession = if (withVideo) createVideoSession() else null
            val remoteUri = "sip:${number.trim()}@${SipConfig.DOMAIN}"
            val call = Dialog(
                direction = Direction.OUTGOING,
                remoteUser = number.trim(),
                callId = "${randomHex(12)}@${localAddress.hostAddress}",
                localTag = randomHex(8),
                remoteTag = null,
                localCseq = 1,
                remoteCseq = 0,
                inviteBranch = newBranch(),
                peer = server,
                remoteTarget = remoteUri,
                routeSet = emptyList(),
                rtp = session,
                video = videoSession,
                remoteMedia = null,
                remoteVideo = null
            )
            dialog = call
            listener.onCall(CallState.OutgoingInit, call.remoteUser, "Создание вызова")
            runCatching { sendInvite(call, initial = true) }
                .onFailure { finishCall(CallState.Error, it.message ?: "Не удалось отправить вызов") }
            worker.schedule({
                val active = dialog
                if (active?.callId == call.callId && !active.connected) {
                    finishCall(CallState.Error, "Сервер не ответил на вызов")
                }
            }, 45, TimeUnit.SECONDS)
        }
    }

    fun accept() {
        worker.execute {
            val call = dialog ?: return@execute
            if (call.direction != Direction.INCOMING || call.accepted) return@execute
            val request = call.incomingInvite ?: return@execute
            val selected = call.remoteMedia?.codec ?: AudioCodec.PCMA
            // A newly accepted call must never advertise hold. In particular,
            // Asterisk treats either a=sendonly or c=0.0.0.0 as remote hold and
            // immediately injects MusicOnHold into the connected bridge.
            val body = localSdp(call, selected, false)
            sendResponse(request, 200, "OK", call.peer, call.localTag, body)
            call.accepted = true
            listener.onCall(CallState.Connected, call.remoteUser, "Ожидание подтверждения")
        }
    }

    fun hangup() {
        worker.execute {
            val call = dialog ?: return@execute
            when {
                call.connected -> {
                    runCatching { sendInDialogRequest(call, "BYE") }
                    finishCall(CallState.End, "Звонок завершён")
                }
                call.direction == Direction.OUTGOING -> {
                    runCatching { sendCancel(call) }
                    finishCall(CallState.End, "Вызов отменён")
                }
                else -> {
                    call.incomingInvite?.let { sendResponse(it, 486, "Busy Here", call.peer, call.localTag) }
                    finishCall(CallState.End, "Вызов отклонён")
                }
            }
        }
    }

    fun toggleMute(): Boolean {
        muted = !muted
        dialog?.rtp?.setMuted(muted)
        return muted
    }

    fun toggleSpeaker(): Boolean {
        speaker = !speaker
        dialog?.rtp?.setSpeaker(speaker)
        return speaker
    }

    fun isMuted(): Boolean = muted

    fun isSpeakerEnabled(): Boolean = speaker

    fun isVideoCall(): Boolean = dialog?.video != null

    fun isVideoCameraEnabled(): Boolean = dialog?.video?.isCameraEnabled() == true

    fun videoCameraRotationDegrees(): Int = dialog?.video?.localRotationDegrees() ?: 0

    fun isFrontVideoCamera(): Boolean = dialog?.video?.isFrontCameraSelected() != false

    fun setVideoSurfaces(localPreview: Surface?, remoteRender: Surface?) {
        dialog?.video?.setSurfaces(localPreview, remoteRender)
    }

    fun toggleVideoCamera(): Boolean {
        val video = dialog?.video ?: return false
        return video.setCameraEnabled(!video.isCameraEnabled())
    }

    fun switchVideoCamera(): Boolean = dialog?.video?.switchCamera() == true

    fun toggleHold(): Boolean {
        val call = dialog ?: return false
        if (!call.connected) return call.held
        val target = !call.held
        worker.execute {
            call.pendingHold = target
            call.localCseq += 1
            call.inviteBranch = newBranch()
            runCatching { sendInvite(call, initial = false, hold = target) }
                .onFailure { call.pendingHold = null; listener.onCall(CallState.Error, call.remoteUser, it.message ?: "Ошибка удержания") }
        }
        return target
    }

    fun sendDtmf(digit: Char) {
        val call = dialog ?: return
        if (call.rtp.sendDtmf(digit)) return
        worker.execute {
            val body = "Signal=$digit\r\nDuration=160\r\n"
            runCatching { sendInDialogRequest(call, "INFO", body, "application/dtmf-relay") }
        }
    }

    fun sendMessage(number: String, text: String) {
        val remote = number.trim()
        val body = text.trim()
        require(remote.isNotBlank()) { "Введите номер абонента" }
        require(body.isNotBlank()) { "Введите сообщение" }
        require(body.toByteArray(Charsets.UTF_8).size <= 4_000) { "Сообщение слишком длинное" }
        worker.execute {
            if (!registered) {
                listener.onMessage(MessageState.Error, remote, body, "Нет подключения к SIP")
                return@execute
            }
            val transaction = MessageTransaction(
                remoteUser = remote,
                text = body,
                callId = "${randomHex(12)}@${localAddress.hostAddress}",
                localTag = randomHex(8),
                branch = newBranch()
            )
            pendingMessages[transaction.callId] = transaction
            listener.onMessage(MessageState.Sending, remote, body, "Отправка…")
            runCatching { sendSipMessage(transaction) }
                .onFailure { failMessage(transaction, it.message ?: "Ошибка сети") }
        }
    }

    fun close() {
        if (!running.getAndSet(false)) return
        keepAlive?.cancel(false)
        registrationRetry?.cancel(false)
        runCatching { dialog?.rtp?.close() }
        runCatching { dialog?.video?.close() }
        dialog = null
        pendingMessages.clear()
        if (registered && username.isNotEmpty()) runCatching { sendRegister(expires = 0) }
        registered = false
        sipSocket.close()
        worker.shutdownNow()
        receiver.interrupt()
    }

    private fun sendRegister(expires: Int) {
        registrationCseq += 1
        registrationRequestedExpires = expires
        val sentCseq = registrationCseq
        registrationPendingCseq = sentCseq
        val requestUri = "sip:${SipConfig.DOMAIN}:${SipConfig.PORT}"
        val branch = newBranch()
        val headers = mutableListOf(
            "Via: SIP/2.0/UDP ${hostPort()};rport;branch=$branch",
            "Max-Forwards: 70",
            "From: <sip:$username@${SipConfig.DOMAIN}>;tag=$registrationTag",
            "To: <sip:$username@${SipConfig.DOMAIN}>",
            "Call-ID: $registrationCallId",
            "CSeq: $registrationCseq REGISTER",
            "Contact: <${contactUri()}>;ob;expires=$expires",
            "Expires: $expires",
            "User-Agent: Tvoice/${BuildConfig.VERSION_NAME} TvoiceSipCore/1.8",
            "Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE",
            "Supported: path, gruu, outbound"
        )
        registrationChallenge?.let { challenge ->
            registrationNonceCount += 1
            val auth = DigestAuth.create(challenge, username, password, "REGISTER", requestUri, registrationNonceCount)
            headers += "$registrationAuthHeader: $auth"
        }
        sendRequest("REGISTER $requestUri SIP/2.0", headers, "", server)
        if (expires > 0) {
            worker.schedule({
                if (registrationPendingCseq == sentCseq && registrationRequestedExpires > 0) {
                    failRegistration("SIP-сервер не ответил", retry = true)
                }
            }, 12, TimeUnit.SECONDS)
        }
    }

    private fun sendInvite(call: Dialog, initial: Boolean, hold: Boolean = false) {
        val requestUri = if (initial) "sip:${call.remoteUser}@${SipConfig.DOMAIN}" else call.remoteTarget
        val toTag = call.remoteTag?.let { ";tag=$it" }.orEmpty()
        val body = localSdp(call, null, hold)
        val headers = mutableListOf(
            "Via: SIP/2.0/UDP ${hostPort()};rport;branch=${call.inviteBranch}",
            "Max-Forwards: 70",
            "From: <sip:$username@${SipConfig.DOMAIN}>;tag=${call.localTag}",
            "To: <sip:${call.remoteUser}@${SipConfig.DOMAIN}>$toTag",
            "Call-ID: ${call.callId}",
            "CSeq: ${call.localCseq} INVITE",
            "Contact: <${contactUri()}>",
            "Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE",
            "Supported: replaces, timer",
            "User-Agent: Tvoice/${BuildConfig.VERSION_NAME} TvoiceSipCore/1.8"
        )
        call.routeSet.forEach { headers += "Route: $it" }
        call.authChallenge?.let { challenge ->
            call.nonceCount += 1
            val auth = DigestAuth.create(challenge, username, password, "INVITE", requestUri, call.nonceCount)
            headers += "${call.authHeaderName}: $auth"
        }
        headers += "Content-Type: application/sdp"
        sendRequest("INVITE $requestUri SIP/2.0", headers, body, call.peer)
    }

    private fun sendCancel(call: Dialog) {
        val uri = "sip:${call.remoteUser}@${SipConfig.DOMAIN}"
        val headers = mutableListOf(
            "Via: SIP/2.0/UDP ${hostPort()};rport;branch=${call.inviteBranch}",
            "Max-Forwards: 70",
            "From: <sip:$username@${SipConfig.DOMAIN}>;tag=${call.localTag}",
            "To: <sip:${call.remoteUser}@${SipConfig.DOMAIN}>${call.remoteTag?.let { ";tag=$it" }.orEmpty()}",
            "Call-ID: ${call.callId}",
            "CSeq: ${call.localCseq} CANCEL",
            "User-Agent: Tvoice/${BuildConfig.VERSION_NAME} TvoiceSipCore/1.8"
        )
        sendRequest("CANCEL $uri SIP/2.0", headers, "", call.peer)
    }

    private fun sendAck(call: Dialog, response: SipMessage, non2xx: Boolean) {
        val uri = if (non2xx && !call.connected) "sip:${call.remoteUser}@${SipConfig.DOMAIN}" else call.remoteTarget
        val branch = if (non2xx) call.inviteBranch else newBranch()
        val headers = mutableListOf(
            "Via: SIP/2.0/UDP ${hostPort()};rport;branch=$branch",
            "Max-Forwards: 70",
            "From: <sip:$username@${SipConfig.DOMAIN}>;tag=${call.localTag}",
            "To: ${response.header("To") ?: "<sip:${call.remoteUser}@${SipConfig.DOMAIN}>"}",
            "Call-ID: ${call.callId}",
            "CSeq: ${response.cseqNumber() ?: call.localCseq} ACK",
            "User-Agent: Tvoice/${BuildConfig.VERSION_NAME} TvoiceSipCore/1.8"
        )
        if (!non2xx) call.routeSet.forEach { headers += "Route: $it" }
        sendRequest("ACK $uri SIP/2.0", headers, "", call.peer)
    }

    private fun sendInDialogRequest(call: Dialog, method: String, body: String = "", contentType: String? = null) {
        call.localCseq += 1
        val headers = mutableListOf(
            "Via: SIP/2.0/UDP ${hostPort()};rport;branch=${newBranch()}",
            "Max-Forwards: 70",
            "From: <sip:$username@${SipConfig.DOMAIN}>;tag=${call.localTag}",
            "To: <sip:${call.remoteUser}@${SipConfig.DOMAIN}>${call.remoteTag?.let { ";tag=$it" }.orEmpty()}",
            "Call-ID: ${call.callId}",
            "CSeq: ${call.localCseq} $method",
            "Contact: <${contactUri()}>",
            "User-Agent: Tvoice/${BuildConfig.VERSION_NAME} TvoiceSipCore/1.8"
        )
        call.routeSet.forEach { headers += "Route: $it" }
        if (contentType != null) headers += "Content-Type: $contentType"
        sendRequest("$method ${call.remoteTarget} SIP/2.0", headers, body, call.peer)
    }

    private fun sendSipMessage(transaction: MessageTransaction) {
        val requestUri = "sip:${transaction.remoteUser}@${SipConfig.DOMAIN}"
        val sentCseq = transaction.cseq
        val headers = mutableListOf(
            "Via: SIP/2.0/UDP ${hostPort()};rport;branch=${transaction.branch}",
            "Max-Forwards: 70",
            "From: <sip:$username@${SipConfig.DOMAIN}>;tag=${transaction.localTag}",
            "To: <sip:${transaction.remoteUser}@${SipConfig.DOMAIN}>",
            "Call-ID: ${transaction.callId}",
            "CSeq: ${transaction.cseq} MESSAGE",
            "Contact: <${contactUri()}>",
            "Content-Type: text/plain; charset=UTF-8",
            "Accept: text/plain",
            "User-Agent: Tvoice/${BuildConfig.VERSION_NAME} TvoiceSipCore/1.8"
        )
        transaction.challenge?.let { challenge ->
            transaction.nonceCount += 1
            val auth = DigestAuth.create(
                challenge,
                username,
                password,
                "MESSAGE",
                requestUri,
                transaction.nonceCount
            )
            headers += "${transaction.authHeaderName}: $auth"
        }
        sendRequest("MESSAGE $requestUri SIP/2.0", headers, transaction.text, server)
        worker.schedule({
            val pending = pendingMessages[transaction.callId]
            if (pending != null && pending.cseq == sentCseq) failMessage(pending, "Сервер не ответил")
        }, 15, TimeUnit.SECONDS)
    }

    private fun receiveLoop() {
        val buffer = ByteArray(65535)
        while (running.get()) {
            val packet = DatagramPacket(buffer, buffer.size)
            try {
                sipSocket.receive(packet)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (_: SocketException) {
                if (!running.get()) break
                continue
            } catch (_: Exception) {
                continue
            }
            val message = SipMessage.parse(packet.data, packet.length) ?: continue
            val source = InetSocketAddress(packet.address, packet.port)
            worker.execute { runCatching { handleMessage(message, source) } }
        }
    }

    private fun handleMessage(message: SipMessage, source: InetSocketAddress) {
        // This client is intentionally bound to one managed PBX. Ignore unsolicited
        // signaling from arbitrary hosts instead of acting as an open UDP SIP endpoint.
        if (source.address != server.address) return
        val status = message.statusCode
        if (status != null) handleResponse(message, status, source) else handleRequest(message, source)
    }

    private fun handleResponse(message: SipMessage, status: Int, source: InetSocketAddress) {
        when (message.cseqMethod()) {
            "REGISTER" -> handleRegisterResponse(message, status)
            "INVITE" -> handleInviteResponse(message, status, source)
            "MESSAGE" -> handleMessageResponse(message, status)
            else -> Unit
        }
    }

    private fun handleMessageResponse(message: SipMessage, status: Int) {
        val callId = message.header("Call-ID") ?: return
        val transaction = pendingMessages[callId] ?: return
        if (message.cseqNumber() != transaction.cseq) return
        when (status) {
            401, 407 -> {
                if (transaction.authAttempts >= 2) {
                    failMessage(transaction, "Сервер отклонил сообщение")
                    return
                }
                val headerName = if (status == 407) "Proxy-Authenticate" else "WWW-Authenticate"
                val challenge = message.header(headerName)?.let(DigestChallenge::parse)
                if (challenge == null) {
                    failMessage(transaction, "Ошибка авторизации сообщения")
                    return
                }
                transaction.challenge = challenge
                transaction.authHeaderName = if (status == 407) "Proxy-Authorization" else "Authorization"
                transaction.authAttempts += 1
                transaction.cseq += 1
                transaction.branch = newBranch()
                runCatching { sendSipMessage(transaction) }
                    .onFailure { failMessage(transaction, it.message ?: "Ошибка сети") }
            }
            in 200..299 -> {
                pendingMessages.remove(callId)
                listener.onMessage(MessageState.Sent, transaction.remoteUser, transaction.text, "Доставлено серверу")
            }
            in 300..699 -> failMessage(
                transaction,
                "SIP $status ${message.startLine.substringAfter(status.toString()).trim()}"
            )
        }
    }

    private fun handleRegisterResponse(message: SipMessage, status: Int) {
        if (message.header("Call-ID") != registrationCallId) return
        val responseCseq = message.cseqNumber() ?: return
        if (responseCseq != registrationCseq) return
        registrationPendingCseq = null
        val mappingChanged = ViaMapping.parse(message.header("Via"))?.let { discovered ->
            val changed = discovered != mappedContact
            mappedContact = discovered
            changed
        } ?: false
        when (status) {
            200 -> {
                registrationAuthAttempts = 0
                if (registrationRequestedExpires == 0) {
                    registered = false
                    keepAlive?.cancel(false)
                    listener.onRegistration(RegistrationState.Cleared, "Регистрация отключена")
                    return
                }
                if (!registered) {
                    registered = true
                    listener.onRegistration(RegistrationState.Ok, "Подключено")
                }
                registrationRetry?.cancel(false)
                retryDelaySeconds = 5L
                keepAlive?.cancel(false)
                keepAlive = worker.schedule({
                    if (running.get() && registered) runCatching { sendRegister(300) }
                }, 25, TimeUnit.SECONDS)
                // A server that accepts REGISTER without a challenge first saw the private Contact.
                // Repeat once with the public received/rport mapping learned from its response.
                if (mappingChanged) worker.schedule({
                    if (running.get() && registered) runCatching { sendRegister(300) }
                }, 250, TimeUnit.MILLISECONDS)
            }
            401, 407 -> {
                if (registrationAuthAttempts >= 2) {
                    failRegistration("Сервер отклонил логин или пароль", retry = false)
                    return
                }
                val headerName = if (status == 407) "Proxy-Authenticate" else "WWW-Authenticate"
                val value = message.header(headerName) ?: run { failRegistration("Сервер не прислал параметры авторизации", retry = false); return }
                val challenge = DigestChallenge.parse(value) ?: run { failRegistration("Не удалось прочитать SIP-аутентификацию", retry = false); return }
                registrationChallenge = challenge
                registrationAuthHeader = if (status == 407) "Proxy-Authorization" else "Authorization"
                registrationAuthAttempts += 1
                runCatching { sendRegister(300) }.onFailure { failRegistration(it.message ?: "Ошибка регистрации") }
            }
            in 300..699 -> failRegistration(
                "SIP $status ${message.startLine.substringAfter(status.toString()).trim()}",
                retry = status == 408 || status >= 500
            )
        }
    }

    private fun handleInviteResponse(message: SipMessage, status: Int, source: InetSocketAddress) {
        val call = dialog ?: return
        if (message.header("Call-ID") != call.callId) return
        call.peer = source
        if (responseEstablishesDialog(status)) {
            call.remoteTag = headerTag(message.header("To")) ?: call.remoteTag
        }
        when (status) {
            100, 180, 183 -> provisionalCallState(status, call.connected)?.let { state ->
                // UDP may deliver a delayed/retransmitted 180 after the final 200 OK,
                // including during hold/resume re-INVITEs. Never re-enable ringback
                // for an already connected dialog.
                val detail = if (state == CallState.OutgoingRinging) "Телефон звонит" else "SIP $status"
                listener.onCall(state, call.remoteUser, detail)
            }
            401, 407 -> {
                sendAck(call, message, non2xx = true)
                // A challenge tag belongs only to the failed transaction. Reusing it would turn
                // the authenticated retry into an in-dialog INVITE and many PBXs answer SIP 481.
                call.remoteTag = null
                if (call.authAttempts >= 2) {
                    finishCall(CallState.Error, "Сервер отклонил вызов")
                    return
                }
                val headerName = if (status == 407) "Proxy-Authenticate" else "WWW-Authenticate"
                val challenge = message.header(headerName)?.let(DigestChallenge::parse)
                if (challenge == null) {
                    finishCall(CallState.Error, "Ошибка авторизации вызова")
                    return
                }
                call.authChallenge = challenge
                call.authHeaderName = if (status == 407) "Proxy-Authorization" else "Authorization"
                call.authAttempts += 1
                call.localCseq += 1
                call.inviteBranch = newBranch()
                sendInvite(call, initial = !call.connected, hold = call.pendingHold ?: call.held)
            }
            in 200..299 -> {
                call.remoteTarget = headerUri(message.header("Contact")) ?: call.remoteTarget
                val routes = message.headers("Record-Route")
                if (routes.isNotEmpty()) call.routeSet = routes.reversed()
                sendAck(call, message, non2xx = false)
                val media = RemoteMedia.fromSdp(message.body, source.address)
                if (media == null) {
                    finishCall(CallState.Error, "Сервер не предложил G.711 аудио")
                    return
                }
                if (!call.connected) {
                    call.remoteMedia = media
                    call.remoteVideo = RemoteVideoMedia.fromSdp(message.body, source.address)
                    if (call.video != null && call.remoteVideo == null) {
                        call.video?.close()
                        call.video = null
                    }
                    call.remoteVideo?.let { videoMedia -> call.video?.updateRemote(videoMedia) }
                    // Stop every signalling tone synchronously before AudioRecord starts.
                    // Otherwise a vendor audio stack can feed the ringback tail into the
                    // microphone and the callee hears it over the caller's first words.
                    call.connected = true
                    call.authAttempts = 0
                    listener.onCall(CallState.Connected, call.remoteUser, "Соединено")
                    try {
                        call.rtp.start(
                            media,
                            initialCaptureGuardMs = POST_CONNECT_CAPTURE_GUARD_MS,
                            initialPlaybackGuardMs = POST_CONNECT_PLAYBACK_GUARD_MS
                        )
                    } catch (error: Exception) {
                        finishCall(CallState.Error, error.message ?: "Не удалось запустить аудио")
                        return
                    }
                    call.rtp.setMuted(muted)
                    call.rtp.setSpeaker(speaker)
                    call.remoteVideo?.let { videoMedia -> call.video?.start(videoMedia) }
                    listener.onCall(CallState.StreamsRunning, call.remoteUser, "Аудио G.711")
                } else {
                    call.remoteMedia = media
                    call.rtp.updateRemote(media)
                    val updatedVideo = RemoteVideoMedia.fromSdp(message.body, source.address)
                    call.remoteVideo = updatedVideo
                    if (updatedVideo != null) {
                        call.video?.updateRemote(updatedVideo)
                    } else {
                        call.video?.close()
                        call.video = null
                    }
                    call.pendingHold?.let { target ->
                        call.held = target
                        call.rtp.setHeld(target)
                        listener.onCall(if (target) CallState.Paused else CallState.StreamsRunning, call.remoteUser, if (target) "Удержание" else "Соединено")
                    }
                    call.pendingHold = null
                }
            }
            in 300..699 -> {
                sendAck(call, message, non2xx = true)
                if (call.connected) {
                    call.pendingHold = null
                    listener.onCall(CallState.StreamsRunning, call.remoteUser, "Удержание не поддержано: SIP $status")
                } else {
                    finishCall(CallState.Error, callFailureMessage(message, status))
                }
            }
        }
    }

    private fun callFailureMessage(message: SipMessage, status: Int): String {
        val reason = message.header("Reason")
            ?.substringAfter("text=", "")
            ?.trim(' ', '"')
            ?.take(140)
            .orEmpty()
        val warning = message.header("Warning")
            ?.substringAfter(' ', "")
            ?.trim()
            ?.take(140)
            .orEmpty()
        val detail = reason.ifBlank { warning }
        val suffix = detail.takeIf(String::isNotBlank)?.let { ": $it" }.orEmpty()
        return when (status) {
            404 -> "SIP 404: номер не найден$suffix"
            480 -> "SIP 480: абонент временно недоступен$suffix"
            486 -> "SIP 486: абонент занят$suffix"
            503 -> "SIP 503: FreePBX не нашёл доступный endpoint или маршрут$suffix"
            else -> "SIP $status ${message.startLine.substringAfter(status.toString()).trim()}$suffix"
        }
    }

    private fun handleRequest(message: SipMessage, source: InetSocketAddress) {
        when (message.method) {
            "INVITE" -> handleIncomingInvite(message, source)
            "MESSAGE" -> handleIncomingMessage(message, source)
            "ACK" -> handleIncomingAck(message, source)
            "BYE" -> {
                val call = dialog
                if (call == null || message.header("Call-ID") != call.callId) {
                    sendResponse(message, 481, "Call/Transaction Does Not Exist", source)
                } else {
                    sendResponse(message, 200, "OK", source, call.localTag)
                    finishCall(CallState.End, "Собеседник завершил звонок")
                }
            }
            "CANCEL" -> {
                val call = dialog
                if (call == null || message.header("Call-ID") != call.callId) {
                    sendResponse(message, 481, "Call/Transaction Does Not Exist", source)
                } else {
                    sendResponse(message, 200, "OK", source, call.localTag)
                    call.incomingInvite?.let { sendResponse(it, 487, "Request Terminated", source, call.localTag) }
                    finishCall(CallState.End, "Вызов отменён")
                }
            }
            "OPTIONS", "INFO", "NOTIFY", "UPDATE" -> sendResponse(message, 200, "OK", source, dialog?.localTag)
            else -> sendResponse(message, 501, "Not Implemented", source, dialog?.localTag)
        }
    }

    private fun handleIncomingMessage(message: SipMessage, source: InetSocketAddress) {
        if (!registered) {
            sendResponse(message, 480, "Temporarily Unavailable", source)
            return
        }
        val contentType = message.header("Content-Type").orEmpty()
        if (contentType.isNotBlank() && !contentType.startsWith("text/plain", ignoreCase = true)) {
            sendResponse(message, 415, "Unsupported Media Type", source)
            return
        }
        val remoteUri = headerUri(message.header("From")).orEmpty()
        val remote = remoteUri.substringAfter("sip:").substringBefore('@').ifBlank { "Неизвестный" }
        val text = message.body.trim().take(4_000)
        if (text.isBlank()) {
            sendResponse(message, 400, "Bad Request", source)
            return
        }
        sendResponse(message, 200, "OK", source)
        val messageId = "${message.header("Call-ID")}:${message.cseqNumber()}"
        if (receivedMessageIds.add(messageId)) {
            while (receivedMessageIds.size > 100) receivedMessageIds.remove(receivedMessageIds.first())
            listener.onMessage(MessageState.Received, remote, text, "Получено")
        }
    }

    private fun handleIncomingInvite(message: SipMessage, source: InetSocketAddress) {
        if (!registered) {
            sendResponse(message, 480, "Temporarily Unavailable", source)
            return
        }
        val callId = message.header("Call-ID") ?: return
        val existing = dialog
        if (existing != null && existing.callId == callId && existing.connected) {
            val media = RemoteMedia.fromSdp(message.body, source.address)
            if (media != null) {
                existing.remoteMedia = media
                existing.rtp.updateRemote(media)
            }
            val videoMedia = RemoteVideoMedia.fromSdp(message.body, source.address)
            if (videoMedia != null) {
                if (existing.video == null) existing.video = createVideoSession()
                existing.remoteVideo = videoMedia
                existing.video?.updateRemote(videoMedia)
            } else {
                existing.remoteVideo = null
                existing.video?.close()
                existing.video = null
            }
            existing.incomingInvite = message
            val audioDirection = SdpMediaDirection.of(message.body, "audio")
            val remoteHold = audioDirection == "sendonly" || audioDirection == "inactive"
            existing.held = remoteHold
            existing.rtp.setHeld(remoteHold)
            sendResponse(message, 200, "OK", source, existing.localTag, localSdp(existing, media?.codec ?: AudioCodec.PCMA, false))
            listener.onCall(if (remoteHold) CallState.Paused else CallState.StreamsRunning, existing.remoteUser, if (remoteHold) "Собеседник удерживает звонок" else "Соединено")
            videoMedia?.let { existing.video?.start(it) }
            return
        }
        if (existing != null) {
            sendResponse(message, 486, "Busy Here", source)
            return
        }
        val remoteUri = headerUri(message.header("From")).orEmpty()
        val remoteUser = remoteUri.substringAfter("sip:").substringBefore('@').ifEmpty { "Неизвестный" }
        val remoteMedia = RemoteMedia.fromSdp(message.body, source.address)
        if (remoteMedia == null) {
            sendResponse(message, 488, "Not Acceptable Here", source)
            return
        }
        val remoteVideo = RemoteVideoMedia.fromSdp(message.body, source.address)
        if (remoteVideo != null) speaker = shouldUseSpeakerForVideo()
        val session = RtpAudioSession(appContext)
        val videoSession = if (remoteVideo != null) createVideoSession() else null
        if (remoteVideo != null) videoSession?.updateRemote(remoteVideo)
        val call = Dialog(
            direction = Direction.INCOMING,
            remoteUser = remoteUser,
            callId = callId,
            localTag = randomHex(8),
            remoteTag = headerTag(message.header("From")),
            localCseq = 0,
            remoteCseq = message.cseqNumber() ?: 1,
            inviteBranch = "",
            peer = source,
            remoteTarget = headerUri(message.header("Contact")) ?: remoteUri,
            routeSet = message.headers("Record-Route"),
            rtp = session,
            video = videoSession,
            remoteMedia = remoteMedia,
            remoteVideo = remoteVideo,
            incomingInvite = message
        )
        dialog = call
        sendResponse(message, 100, "Trying", source, call.localTag)
        sendResponse(message, 180, "Ringing", source, call.localTag)
        listener.onCall(CallState.IncomingReceived, remoteUser, "Входящий вызов")
        worker.schedule({
            val active = dialog
            if (active?.callId == call.callId && !active.accepted && !active.connected) {
                active.incomingInvite?.let {
                    runCatching { sendResponse(it, 480, "Temporarily Unavailable", active.peer, active.localTag) }
                }
                finishCall(CallState.End, "Пропущенный вызов")
            }
        }, 60, TimeUnit.SECONDS)
    }

    private fun handleIncomingAck(message: SipMessage, source: InetSocketAddress) {
        val call = dialog ?: return
        if (message.header("Call-ID") != call.callId || call.direction != Direction.INCOMING || !call.accepted) return
        call.peer = source
        val media = call.remoteMedia ?: return
        if (!call.connected) {
            try {
                call.rtp.start(media)
                call.remoteVideo?.let { videoMedia -> call.video?.start(videoMedia) }
            } catch (error: Exception) {
                finishCall(CallState.Error, error.message ?: "Не удалось запустить аудио")
                return
            }
            call.rtp.setMuted(muted)
            call.rtp.setSpeaker(speaker)
            call.connected = true
            listener.onCall(CallState.StreamsRunning, call.remoteUser, "Аудио G.711")
        }
    }

    private fun sendResponse(
        request: SipMessage,
        code: Int,
        reason: String,
        target: InetSocketAddress,
        localTag: String? = null,
        body: String = ""
    ) {
        val headers = mutableListOf<String>()
        request.headers("Via").forEach { headers += "Via: $it" }
        request.header("From")?.let { headers += "From: $it" }
        val originalTo = request.header("To").orEmpty()
        val to = if (localTag != null && !originalTo.contains(";tag=", true)) "$originalTo;tag=$localTag" else originalTo
        headers += "To: $to"
        request.header("Call-ID")?.let { headers += "Call-ID: $it" }
        request.header("CSeq")?.let { headers += "CSeq: $it" }
        headers += "Contact: <${contactUri()}>"
        headers += "Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE"
        headers += "User-Agent: Tvoice/${BuildConfig.VERSION_NAME} TvoiceSipCore/1.8"
        if (body.isNotEmpty()) headers += "Content-Type: application/sdp"
        sendRequest("SIP/2.0 $code $reason", headers, body, target)
    }

    private fun sendRequest(startLine: String, headers: List<String>, body: String, target: InetSocketAddress) {
        val bodyBytes = body.toByteArray(Charsets.UTF_8)
        val text = buildString {
            append(startLine).append("\r\n")
            headers.forEach { append(it).append("\r\n") }
            append("Content-Length: ").append(bodyBytes.size).append("\r\n\r\n")
            append(body)
        }
        val bytes = text.toByteArray(Charsets.UTF_8)
        sipSocket.send(DatagramPacket(bytes, bytes.size, target))
    }

    private fun localSdp(call: Dialog, selected: AudioCodec?, hold: Boolean): String {
        val address = localAddress.hostAddress
        val sessionId = System.currentTimeMillis()
        val payloads = if (selected == null) "8 0 101" else "${selected.payloadType} 101"
        return buildString {
            append("v=0\r\n")
            append("o=Tvoice $sessionId 1 IN IP4 $address\r\n")
            append("s=Tvoice\r\n")
            append("c=IN IP4 $address\r\n")
            append("t=0 0\r\n")
            append("m=audio ${call.rtp.localPort} RTP/AVP $payloads\r\n")
            if (selected == null || selected == AudioCodec.PCMA) append("a=rtpmap:8 PCMA/8000\r\n")
            if (selected == null || selected == AudioCodec.PCMU) append("a=rtpmap:0 PCMU/8000\r\n")
            append("a=rtpmap:101 telephone-event/8000\r\n")
            append("a=fmtp:101 0-16\r\n")
            append("a=ptime:20\r\n")
            append(if (hold) "a=sendonly\r\n" else "a=sendrecv\r\n")
            call.video?.let { video ->
                val payload = call.remoteVideo?.payloadType ?: VIDEO_PAYLOAD_TYPE
                append("m=video ${video.localPort} RTP/AVP $payload\r\n")
                append("a=rtpmap:$payload H264/90000\r\n")
                append("a=fmtp:$payload packetization-mode=1;profile-level-id=42e01f;level-asymmetry-allowed=1\r\n")
                append("a=extmap:4 urn:3gpp:video-orientation\r\n")
                append("a=framerate:24\r\n")
                append(
                    when {
                        hold -> "a=inactive\r\n"
                        call.remoteVideo == null && video.canCapture -> "a=sendrecv\r\n"
                        call.remoteVideo == null -> "a=recvonly\r\n"
                        video.canCapture && call.remoteVideo?.sendsVideo == true && call.remoteVideo?.receivesVideo == true -> "a=sendrecv\r\n"
                        video.canCapture && call.remoteVideo?.receivesVideo == true -> "a=sendonly\r\n"
                        call.remoteVideo?.sendsVideo == true -> "a=recvonly\r\n"
                        else -> "a=inactive\r\n"
                    }
                )
            }
        }
    }

    private fun finishCall(state: CallState, message: String) {
        val call = dialog ?: return
        dialog = null
        runCatching { call.rtp.close() }
        runCatching { call.video?.close() }
        muted = false
        speaker = false
        listener.onCall(state, call.remoteUser, message)
        listener.onCall(CallState.Released, call.remoteUser, message)
    }

    private fun createVideoSession(): RtpVideoSession = RtpVideoSession(
        appContext,
        errorListener = { message ->
            worker.execute {
                val call = dialog ?: return@execute
                listener.onCall(CallState.StreamsRunning, call.remoteUser, "Видео: $message")
            }
        },
        remoteRotationListener = { rotation ->
            worker.execute {
                val call = dialog ?: return@execute
                listener.onCall(CallState.StreamsRunning, call.remoteUser, "Видео:rotation=$rotation")
            }
        },
        localRotationListener = { rotation ->
            worker.execute {
                val call = dialog ?: return@execute
                listener.onCall(CallState.StreamsRunning, call.remoteUser, "Видео:local-rotation=$rotation")
            }
        }
    )

    private fun shouldUseSpeakerForVideo(): Boolean {
        val external = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { device ->
            device.type in setOf(
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_USB_HEADSET
            ) || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && device.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
        }
        return !external
    }

    private companion object {
        const val VIDEO_PAYLOAD_TYPE = 96
        const val POST_CONNECT_CAPTURE_GUARD_MS = 1_100L
        const val POST_CONNECT_PLAYBACK_GUARD_MS = 450L
    }

    private fun failMessage(transaction: MessageTransaction, message: String) {
        if (pendingMessages.remove(transaction.callId) == null) return
        listener.onMessage(MessageState.Error, transaction.remoteUser, transaction.text, message)
    }

    private fun failRegistration(message: String, retry: Boolean = true) {
        registered = false
        registrationPendingCseq = null
        keepAlive?.cancel(false)
        registrationRetry?.cancel(false)
        listener.onRegistration(RegistrationState.Failed, message)
        if (!retry || !running.get() || username.isBlank() || password.isBlank()) return
        val delay = retryDelaySeconds
        retryDelaySeconds = (retryDelaySeconds * 2).coerceAtMost(60L)
        registrationRetry = worker.schedule({
            if (!running.get() || username.isBlank() || password.isBlank() || registered) return@schedule
            listener.onRegistration(RegistrationState.Progress, "Повторное подключение к SIP…")
            registrationCallId = "${randomHex(12)}@${localAddress.hostAddress}"
            registrationTag = randomHex(8)
            registrationCseq = 0
            registrationChallenge = null
            registrationAuthAttempts = 0
            registrationNonceCount = 0
            runCatching { sendRegister(expires = 300) }
                .onFailure { failRegistration(it.message ?: "Ошибка сети", retry = true) }
        }, delay, TimeUnit.SECONDS)
    }

    private fun resolveLocalAddress(): InetAddress {
        // DatagramSocket.connect() may still report the wildcard address on some
        // Android network stacks until the first packet is sent. Advertising that
        // value in SDP is not harmless: RFC-compatible PBXs interpret 0.0.0.0 as
        // hold and start MusicOnHold even though the call timer is already running.
        val activeNetworkAddress = runCatching {
            val connectivity = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            connectivity.activeNetwork
                ?.let(connectivity::getLinkProperties)
                ?.linkAddresses
                ?.asSequence()
                ?.map { it.address }
                ?.firstOrNull(::isUsableIpv4Address)
        }.getOrNull()
        if (activeNetworkAddress != null) return activeNetworkAddress

        val routedAddress = runCatching {
            DatagramSocket().use { probe ->
                probe.connect(server)
                probe.localAddress.takeIf(::isUsableIpv4Address)
            }
        }.getOrNull()
        if (routedAddress != null) return routedAddress

        val interfaceAddress = runCatching {
            Collections.list(NetworkInterface.getNetworkInterfaces())
                .asSequence()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { Collections.list(it.inetAddresses).asSequence() }
                .firstOrNull(::isUsableIpv4Address)
        }.getOrNull()
        if (interfaceAddress != null) return interfaceAddress

        // Registration cannot provide usable RTP without a real interface. Keep a
        // non-hold address here so the SIP state remains valid until network retry.
        return InetAddress.getLoopbackAddress()
    }

    private fun isUsableIpv4Address(address: InetAddress): Boolean =
        address is Inet4Address &&
            !address.isAnyLocalAddress &&
            !address.isLoopbackAddress &&
            !address.isLinkLocalAddress

    private fun contactUri(): String = "sip:$username@${contactHostPort()};transport=udp"

    private fun contactHostPort(): String {
        val mapping = mappedContact ?: return hostPort()
        val formatted = if (mapping.address.contains(':')) "[${mapping.address}]" else mapping.address
        return "$formatted:${mapping.port}"
    }

    private fun hostPort(): String {
        val host = localAddress.hostAddress ?: "0.0.0.0"
        val formatted = if (host.contains(':')) "[$host]" else host
        return "$formatted:${sipSocket.localPort}"
    }

    private fun newBranch(): String = "z9hG4bK-${randomHex(10)}"
}
