import Foundation

@MainActor
final class ChatAPIClient: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var incomingVideoCall: VideoCallInvite?
    @Published private(set) var lastEventError: String?

    private let session: URLSession
    private var accessToken = ""
    private var socket: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    var onChatChanged: (() -> Void)?
    var onVideoCallAnswered: ((String) -> Void)?
    var onVideoCallEnded: ((String, String) -> Void)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func login(sipNumber: String, password: String) async throws -> LoginResponse {
        let body = try JSONEncoder().encode(LoginRequest(sipNumber: sipNumber, password: password))
        let response: LoginResponse = try await request("/v1/auth/login", method: "POST", body: body, authenticated: false)
        accessToken = response.accessToken
        connectWebSocket()
        return response
    }

    func logout() {
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        accessToken = ""
        isConnected = false
        incomingVideoCall = nil
    }

    func contacts() async throws -> [Contact] {
        let response: ContactsResponse = try await request("/v1/contacts")
        return response.contacts
    }

    func conversations() async throws -> [Conversation] {
        let response: ConversationsResponse = try await request("/v1/conversations")
        return response.conversations
    }

    func callLogs() async throws -> [CallRecord] {
        let response: CallLogsResponse = try await request("/v1/calls/history")
        return response.calls
    }

    func ensureConversation(peer: String) async throws -> Conversation {
        let body = try JSONEncoder().encode(DirectRequest(peerSipNumber: peer))
        let response: ConversationResponse = try await request("/v1/conversations/direct", method: "POST", body: body)
        return response.conversation
    }

    func messages(conversationID: String) async throws -> [ChatMessage] {
        let response: MessagesResponse = try await request("/v1/conversations/\(conversationID)/messages?limit=100")
        return response.messages
    }

    func sendMessage(conversationID: String, text: String) async throws -> ChatMessage {
        let body = try JSONEncoder().encode(MessageRequest(body: text))
        let response: MessageResponse = try await request(
            "/v1/conversations/\(conversationID)/messages",
            method: "POST",
            body: body
        )
        return response.message
    }

    func markRead(conversationID: String) async throws {
        let _: EmptyResponse = try await request("/v1/conversations/\(conversationID)/read", method: "POST", body: Data("{}".utf8))
    }

    func startVideoCall(peer: String) async throws -> VideoCallCredentials {
        let body = try JSONEncoder().encode(DirectRequest(peerSipNumber: peer))
        return try await request("/v1/video/calls", method: "POST", body: body)
    }

    func startAudioCall(peer: String) async throws -> VideoCallCredentials {
        let body = try JSONEncoder().encode(DirectRequest(peerSipNumber: peer))
        return try await request("/v1/video/calls?mode=audio", method: "POST", body: body)
    }

    func answerVideoCall(callID: String) async throws -> VideoCallCredentials {
        try await request("/v1/video/calls/\(callID)/answer", method: "POST", body: Data("{}".utf8))
    }

    func addVideoParticipants(callID: String, peers: [String]) async throws -> VideoCallParticipantsResponse {
        let body = try JSONEncoder().encode(VideoParticipantsRequest(peerSipNumbers: peers))
        return try await request("/v1/video/calls/\(callID)/participants", method: "POST", body: body)
    }

    func rejectVideoCall(callID: String) async {
        try? await emptyRequest("/v1/video/calls/\(callID)/reject")
        if incomingVideoCall?.id == callID { incomingVideoCall = nil }
    }

    func endVideoCall(callID: String) async {
        try? await emptyRequest("/v1/video/calls/\(callID)/end")
    }

    func clearIncomingCall(_ callID: String) {
        if incomingVideoCall?.id == callID { incomingVideoCall = nil }
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        authenticated: Bool = true
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: AppConfig.chatBaseURL) else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard !accessToken.isEmpty else { throw APIError.notAuthenticated }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? "unknown"
            throw APIError.server(http.statusCode, code)
        }
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func emptyRequest(_ path: String) async throws {
        guard let url = URL(string: path, relativeTo: AppConfig.chatBaseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
    }

    private func connectWebSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        guard !accessToken.isEmpty,
              var components = URLComponents(url: AppConfig.chatBaseURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = "wss"
        components.path = "/v1/ws"
        components.queryItems = [URLQueryItem(name: "token", value: accessToken)]
        guard let url = components.url else { return }
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        isConnected = true
        receiveNext(on: task)
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            Task { @MainActor in
                guard self.socket === task else { return }
                switch result {
                case let .success(message):
                    let text: String
                    switch message {
                    case let .string(value): text = value
                    case let .data(data): text = String(decoding: data, as: UTF8.self)
                    @unknown default: text = ""
                    }
                    self.handleEvent(text)
                    self.receiveNext(on: task)
                case let .failure(error):
                    self.isConnected = false
                    self.lastEventError = error.localizedDescription
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !accessToken.isEmpty else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.connectWebSocket()
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "message.new", "message.delivered", "message.read":
            onChatChanged?()
        case "video.call.incoming":
            guard let id = json["callId"] as? String,
                  let from = json["from"] as? [String: Any],
                  let number = from["sipNumber"] as? String else { return }
            let name = (from["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? number
            let expires = json["expiresAt"] as? String ?? ""
            incomingVideoCall = VideoCallInvite(id: id, peerNumber: number, peerName: name, expiresAt: expires)
        case "video.call.answered":
            if let id = json["callId"] as? String { onVideoCallAnswered?(id) }
        case "video.call.rejected", "video.call.ended":
            if let id = json["callId"] as? String {
                let reason = (json["reason"] as? String) ?? (type.hasSuffix("rejected") ? "rejected" : "ended")
                onVideoCallEnded?(id, reason)
                if incomingVideoCall?.id == id { incomingVideoCall = nil }
            }
        default:
            break
        }
    }
}

private struct LoginRequest: Encodable { let sipNumber: String; let password: String }
private struct DirectRequest: Encodable { let peerSipNumber: String }
private struct VideoParticipantsRequest: Encodable { let peerSipNumbers: [String] }
private struct MessageRequest: Encodable { let body: String }
private struct ContactsResponse: Decodable { let contacts: [Contact] }
private struct ConversationsResponse: Decodable { let conversations: [Conversation] }
private struct CallLogsResponse: Decodable { let calls: [CallRecord] }
private struct ConversationResponse: Decodable { let conversation: Conversation }
private struct MessagesResponse: Decodable { let messages: [ChatMessage] }
private struct MessageResponse: Decodable { let message: ChatMessage }
private struct ErrorResponse: Decodable { let error: String }
private struct EmptyResponse: Decodable { init() {} }
