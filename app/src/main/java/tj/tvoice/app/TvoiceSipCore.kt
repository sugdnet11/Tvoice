package tj.tvoice.app

import android.content.Context
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketException
import java.net.SocketTimeoutException
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
        var remoteMedia: RemoteMedia?,
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

    private enum class Direction { OUTGOING, INCOMING }

    private val appContext = context.applicationContext
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
    private var registered = false
    private var keepAlive: ScheduledFuture<*>? = null
    private var dialog: Dialog? = null
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
            listener.onRegistration(RegistrationState.Progress, "Регистрация на ${SipConfig.DOMAIN}")
            runCatching { sendRegister(expires = 300) }
                .onFailure { failRegistration(it.message ?: "Ошибка сети") }
        }
    }

    fun unregister() {
        worker.execute {
            keepAlive?.cancel(false)
            if (registered && username.isNotEmpty()) runCatching { sendRegister(expires = 0) }
            registered = false
            listener.onRegistration(RegistrationState.Cleared, "Регистрация отключена")
        }
    }

    fun call(number: String) {
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
            val session = RtpAudioSession(appContext)
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
                remoteMedia = null
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
            val body = localSdp(call.rtp, selected, call.held)
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

    fun close() {
        if (!running.getAndSet(false)) return
        keepAlive?.cancel(false)
        runCatching { dialog?.rtp?.close() }
        dialog = null
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
        val requestUri = "sip:${SipConfig.DOMAIN}:${SipConfig.PORT}"
        val branch = newBranch()
        val headers = mutableListOf(
            "Via: SIP/2.0/UDP ${hostPort()};rport;branch=$branch",
            "Max-Forwards: 70",
            "From: <sip:$username@${SipConfig.DOMAIN}>;tag=$registrationTag",
            "To: <sip:$username@${SipConfig.DOMAIN}>",
            "Call-ID: $registrationCallId",
            "CSeq: $registrationCseq REGISTER",
            "Contact: <${contactUri()}>;expires=$expires",
            "Expires: $expires",
            "User-Agent: Tvoice/0.4 TvoiceSipCore/1.0",
            "Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE"
        )
        registrationChallenge?.let { challenge ->
            registrationNonceCount += 1
            val auth = DigestAuth.create(challenge, username, password, "REGISTER", requestUri, registrationNonceCount)
            headers += "$registrationAuthHeader: $auth"
        }
        sendRequest("REGISTER $requestUri SIP/2.0", headers, "", server)
        if (expires > 0 && !registered) {
            worker.schedule({
                if (!registered && registrationCseq == sentCseq) {
                    failRegistration("SIP-сервер не ответил")
                }
            }, 12, TimeUnit.SECONDS)
        }
    }

    private fun sendInvite(call: Dialog, initial: Boolean, hold: Boolean = false) {
        val requestUri = if (initial) "sip:${call.remoteUser}@${SipConfig.DOMAIN}" else call.remoteTarget
        val toTag = call.remoteTag?.let { ";tag=$it" }.orEmpty()
        val body = localSdp(call.rtp, null, hold)
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
            "User-Agent: Tvoice/0.4 TvoiceSipCore/1.0"
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
            "User-Agent: Tvoice/0.4 TvoiceSipCore/1.0"
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
            "User-Agent: Tvoice/0.4 TvoiceSipCore/1.0"
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
            "User-Agent: Tvoice/0.4 TvoiceSipCore/1.0"
        )
        call.routeSet.forEach { headers += "Route: $it" }
        if (contentType != null) headers += "Content-Type: $contentType"
        sendRequest("$method ${call.remoteTarget} SIP/2.0", headers, body, call.peer)
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
        val status = message.statusCode
        if (status != null) handleResponse(message, status, source) else handleRequest(message, source)
    }

    private fun handleResponse(message: SipMessage, status: Int, source: InetSocketAddress) {
        when (message.cseqMethod()) {
            "REGISTER" -> handleRegisterResponse(message, status)
            "INVITE" -> handleInviteResponse(message, status, source)
            else -> Unit
        }
    }

    private fun handleRegisterResponse(message: SipMessage, status: Int) {
        if (message.header("Call-ID") != registrationCallId) return
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
                keepAlive?.cancel(false)
                keepAlive = worker.schedule({
                    if (running.get() && registered) runCatching { sendRegister(300) }
                }, 240, TimeUnit.SECONDS)
            }
            401, 407 -> {
                if (registrationAuthAttempts >= 2) {
                    failRegistration("Сервер отклонил логин или пароль")
                    return
                }
                val headerName = if (status == 407) "Proxy-Authenticate" else "WWW-Authenticate"
                val value = message.header(headerName) ?: run { failRegistration("Сервер не прислал параметры авторизации"); return }
                val challenge = DigestChallenge.parse(value) ?: run { failRegistration("Не удалось прочитать SIP-аутентификацию"); return }
                registrationChallenge = challenge
                registrationAuthHeader = if (status == 407) "Proxy-Authorization" else "Authorization"
                registrationAuthAttempts += 1
                runCatching { sendRegister(300) }.onFailure { failRegistration(it.message ?: "Ошибка регистрации") }
            }
            in 300..699 -> failRegistration("SIP $status ${message.startLine.substringAfter(status.toString()).trim()}")
        }
    }

    private fun handleInviteResponse(message: SipMessage, status: Int, source: InetSocketAddress) {
        val call = dialog ?: return
        if (message.header("Call-ID") != call.callId) return
        call.peer = source
        call.remoteTag = headerTag(message.header("To")) ?: call.remoteTag
        when (status) {
            100, 183 -> listener.onCall(CallState.OutgoingProgress, call.remoteUser, "SIP $status")
            180 -> listener.onCall(CallState.OutgoingRinging, call.remoteUser, "Телефон звонит")
            401, 407 -> {
                sendAck(call, message, non2xx = true)
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
                    try {
                        call.rtp.start(media)
                    } catch (error: Exception) {
                        finishCall(CallState.Error, error.message ?: "Не удалось запустить аудио")
                        return
                    }
                    call.rtp.setMuted(muted)
                    call.rtp.setSpeaker(speaker)
                    call.connected = true
                    call.authAttempts = 0
                    listener.onCall(CallState.Connected, call.remoteUser, "Соединено")
                    listener.onCall(CallState.StreamsRunning, call.remoteUser, "Аудио G.711")
                } else {
                    call.remoteMedia = media
                    call.rtp.updateRemote(media)
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
                    finishCall(CallState.Error, "SIP $status ${message.startLine.substringAfter(status.toString()).trim()}")
                }
            }
        }
    }

    private fun handleRequest(message: SipMessage, source: InetSocketAddress) {
        when (message.method) {
            "INVITE" -> handleIncomingInvite(message, source)
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
            existing.incomingInvite = message
            val remoteHold = message.body.contains("a=sendonly", true) || message.body.contains("a=inactive", true)
            existing.held = remoteHold
            existing.rtp.setHeld(remoteHold)
            sendResponse(message, 200, "OK", source, existing.localTag, localSdp(existing.rtp, media?.codec ?: AudioCodec.PCMA, false))
            listener.onCall(if (remoteHold) CallState.Paused else CallState.StreamsRunning, existing.remoteUser, if (remoteHold) "Собеседник удерживает звонок" else "Соединено")
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
        val session = RtpAudioSession(appContext)
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
            remoteMedia = remoteMedia,
            incomingInvite = message
        )
        dialog = call
        sendResponse(message, 100, "Trying", source, call.localTag)
        sendResponse(message, 180, "Ringing", source, call.localTag)
        listener.onCall(CallState.IncomingReceived, remoteUser, "Входящий вызов")
    }

    private fun handleIncomingAck(message: SipMessage, source: InetSocketAddress) {
        val call = dialog ?: return
        if (message.header("Call-ID") != call.callId || call.direction != Direction.INCOMING || !call.accepted) return
        call.peer = source
        val media = call.remoteMedia ?: return
        if (!call.connected) {
            try {
                call.rtp.start(media)
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
        headers += "User-Agent: Tvoice/0.4 TvoiceSipCore/1.0"
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

    private fun localSdp(session: RtpAudioSession, selected: AudioCodec?, hold: Boolean): String {
        val address = localAddress.hostAddress
        val sessionId = System.currentTimeMillis()
        val payloads = if (selected == null) "8 0 101" else "${selected.payloadType} 101"
        return buildString {
            append("v=0\r\n")
            append("o=Tvoice $sessionId 1 IN IP4 $address\r\n")
            append("s=Tvoice\r\n")
            append("c=IN IP4 $address\r\n")
            append("t=0 0\r\n")
            append("m=audio ${session.localPort} RTP/AVP $payloads\r\n")
            if (selected == null || selected == AudioCodec.PCMA) append("a=rtpmap:8 PCMA/8000\r\n")
            if (selected == null || selected == AudioCodec.PCMU) append("a=rtpmap:0 PCMU/8000\r\n")
            append("a=rtpmap:101 telephone-event/8000\r\n")
            append("a=fmtp:101 0-16\r\n")
            append("a=ptime:20\r\n")
            append(if (hold) "a=sendonly\r\n" else "a=sendrecv\r\n")
        }
    }

    private fun finishCall(state: CallState, message: String) {
        val call = dialog ?: return
        dialog = null
        runCatching { call.rtp.close() }
        muted = false
        speaker = false
        listener.onCall(state, call.remoteUser, message)
        listener.onCall(CallState.Released, call.remoteUser, message)
    }

    private fun failRegistration(message: String) {
        registered = false
        keepAlive?.cancel(false)
        listener.onRegistration(RegistrationState.Failed, message)
    }

    private fun resolveLocalAddress(): InetAddress = runCatching {
        DatagramSocket().use { probe ->
            probe.connect(server)
            probe.localAddress
        }
    }.getOrElse { InetAddress.getByName("0.0.0.0") }

    private fun contactUri(): String = "sip:$username@${hostPort()};transport=udp"

    private fun hostPort(): String {
        val host = localAddress.hostAddress ?: "0.0.0.0"
        val formatted = if (host.contains(':')) "[$host]" else host
        return "$formatted:${sipSocket.localPort}"
    }

    private fun newBranch(): String = "z9hG4bK-${randomHex(10)}"
}
