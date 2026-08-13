using System.Text.Json.Serialization;

namespace Tvoice.Windows.Models;

public sealed record TvoiceUser(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("sipNumber")] string SipNumber,
    [property: JsonPropertyName("displayName")] string DisplayName);

public sealed record LoginResponse(
    [property: JsonPropertyName("accessToken")] string AccessToken,
    [property: JsonPropertyName("expiresIn")] int ExpiresIn,
    [property: JsonPropertyName("user")] TvoiceUser User);

public sealed record ContactsResponse(
    [property: JsonPropertyName("contacts")] IReadOnlyList<TvoiceUser> Contacts);

public sealed record MessagePreview(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("body")] string? Body,
    [property: JsonPropertyName("createdAt")] DateTimeOffset? CreatedAt);

public sealed record Conversation(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("peer")] TvoiceUser Peer,
    [property: JsonPropertyName("lastMessage")] MessagePreview? LastMessage);

public sealed record ConversationsResponse(
    [property: JsonPropertyName("conversations")] IReadOnlyList<Conversation> Conversations);

public sealed record DirectConversationResponse(
    [property: JsonPropertyName("conversation")] Conversation Conversation);

public sealed record ChatMessage(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("conversationId")] string? ConversationId,
    [property: JsonPropertyName("sender")] TvoiceUser Sender,
    [property: JsonPropertyName("body")] string Body,
    [property: JsonPropertyName("createdAt")] DateTimeOffset CreatedAt,
    [property: JsonPropertyName("status")] string? Status,
    [property: JsonPropertyName("attachment")] ChatAttachment? Attachment);

public sealed record ChatAttachment(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("mimeType")] string MimeType,
    [property: JsonPropertyName("size")] long Size);

public sealed record MessagesResponse(
    [property: JsonPropertyName("messages")] IReadOnlyList<ChatMessage> Messages);

public sealed record SendMessageResponse(
    [property: JsonPropertyName("message")] ChatMessage Message);

public sealed record ChatRealtimeEvent(
    string Type,
    ChatMessage? Message,
    string? ConversationId,
    DateTimeOffset? ThroughCreatedAt,
    string? CallId = null,
    TvoiceUser? From = null,
    string? Reason = null,
    DateTimeOffset? ExpiresAt = null);

public sealed record VideoCallCredentials(
    [property: JsonPropertyName("callId")] string CallId,
    [property: JsonPropertyName("room")] string Room,
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("token")] string Token,
    [property: JsonPropertyName("peer")] TvoiceUser Peer,
    [property: JsonPropertyName("expiresAt")] DateTimeOffset? ExpiresAt,
    [property: JsonPropertyName("delivered")] bool? Delivered);

public sealed record IncomingVideoCall(
    string CallId,
    TvoiceUser From,
    DateTimeOffset? ExpiresAt);

public sealed record CallHistoryEntry(
    string PeerNumber,
    bool IsIncoming,
    bool IsVideo,
    DateTimeOffset StartedAt,
    int DurationSeconds,
    string Result)
{
    [JsonIgnore] public string Kind => IsVideo ? "Видео" : "Аудио";
    [JsonIgnore] public string Direction => IsIncoming ? "Входящий" : "Исходящий";
    [JsonIgnore] public string Duration => DurationSeconds > 0
        ? TimeSpan.FromSeconds(DurationSeconds).ToString(DurationSeconds >= 3600 ? @"hh\:mm\:ss" : @"mm\:ss")
        : Result;
}
