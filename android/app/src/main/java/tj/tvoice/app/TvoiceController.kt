package tj.tvoice.app

import android.view.Surface

/** UI-facing contract. Activities depend on this boundary, not on SIP socket internals. */
interface TvoiceController {
    val activeUsername: String
    val registrationState: RegistrationState
    val callState: CallState
    val remoteNumber: String
    val callConnectedAtMillis: Long?
    val isMainUiVisible: Boolean
    val isVideoCall: Boolean

    fun addObserver(observer: SipManager.Observer)
    fun removeObserver(observer: SipManager.Observer)
    fun setMainUiVisible(visible: Boolean)
    fun login(username: String, password: String)
    fun addAccount(username: String, password: String)
    fun selectAccount(username: String)
    fun restoreSavedAccount(): Boolean
    fun savedUsername(): String?
    fun accountUsernames(): List<String>
    fun call(number: String)
    fun videoCall(number: String)
    fun accept()
    fun hangup()
    fun sendDtmf(digit: Char)
    fun sendMessage(number: String, text: String)
    fun toggleHold(): Boolean
    fun toggleMute(): Boolean
    fun toggleSpeaker(): Boolean
    fun isMuted(): Boolean
    fun isSpeakerEnabled(): Boolean
    fun isVideoCameraEnabled(): Boolean
    fun videoCameraRotationDegrees(): Int
    fun isFrontVideoCamera(): Boolean
    fun toggleVideoCamera(): Boolean
    fun switchVideoCamera(): Boolean
    fun setVideoSurfaces(localPreview: Surface?, remoteRender: Surface?)
    fun supportsConference(): Boolean
    fun logout()
}
