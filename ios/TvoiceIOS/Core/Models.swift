import Foundation

struct TvoiceUser: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let sipNumber: String
    let displayName: String
}

struct LoginResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int
    let user: TvoiceUser
}

struct Contact: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let sipNumber: String
    let displayName: String
}

struct Conversation: Decodable, Identifiable, Hashable, Sendable {
    struct LastMessage: Decodable, Hashable, Sendable {
        let id: String
        let body: String?
        let createdAt: String?
    }

    let id: String
    let peer: Contact
    let lastMessage: LastMessage?
}

enum MessageStatus: String, Codable, Sendable {
    case sent
    case delivered
    case read
    case received
    case failed
}

struct ChatMessage: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let sender: TvoiceUser
    let body: String
    let createdAt: String
    let status: MessageStatus
}

struct VideoCallInvite: Identifiable, Hashable, Sendable {
    let id: String
    let peerNumber: String
    let peerName: String
    let expiresAt: String
}

struct VideoCallCredentials: Decodable, Identifiable, Sendable {
    let callId: String
    let room: String
    let url: String
    let token: String
    let peer: TvoiceUser

    var id: String { callId }
}

enum CallDirection: String, Codable, Sendable {
    case incoming
    case outgoing
    case missed
}

struct CallRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let peerNumber: String
    let peerName: String
    let direction: CallDirection
    let timestamp: Date
    let isVideo: Bool
}

struct StoredCredentials: Codable, Sendable {
    let sipNumber: String
    let password: String
}

enum APIError: LocalizedError {
    case invalidResponse
    case server(Int, String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Сервер вернул некорректный ответ"
        case let .server(status, code):
            switch code {
            case "invalid_credentials": return "Неверный логин или пароль"
            case "contact_not_found": return "Абонент не найден"
            case "video_unavailable": return "Сервер видеозвонков недоступен"
            case "call_not_found": return "Видеозвонок уже завершён"
            case "cannot_call_yourself": return "Нельзя позвонить самому себе"
            default: return "Ошибка сервера \(status): \(code)"
            }
        case .notAuthenticated:
            return "Сначала войдите в аккаунт"
        }
    }
}
