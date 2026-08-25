class TvoiceUser {
  const TvoiceUser({
    required this.id,
    required this.sipNumber,
    required this.displayName,
  });

  final String id;
  final String sipNumber;
  final String displayName;

  factory TvoiceUser.fromJson(Map<String, dynamic> json) => TvoiceUser(
    id: json['id']?.toString() ?? '',
    sipNumber: json['sipNumber']?.toString() ?? '',
    displayName:
        json['displayName']?.toString() ?? json['sipNumber']?.toString() ?? '',
  );
}

class Conversation {
  const Conversation({required this.id, required this.peer, this.lastMessage});

  final String id;
  final TvoiceUser peer;
  final ChatMessage? lastMessage;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id']?.toString() ?? '',
    peer: TvoiceUser.fromJson(json['peer'] as Map<String, dynamic>),
    lastMessage: json['lastMessage'] is Map<String, dynamic>
        ? ChatMessage.fromPreview(
            json['lastMessage'] as Map<String, dynamic>,
            json['id']?.toString() ?? '',
          )
        : null,
  );
}

enum MessageStatus { sent, delivered, read, received }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.createdAt,
    this.sender,
    this.status = MessageStatus.sent,
  });

  final String id;
  final String conversationId;
  final TvoiceUser? sender;
  final String body;
  final DateTime createdAt;
  final MessageStatus status;

  bool sentBy(String userId) => sender?.id == userId;

  ChatMessage copyWith({MessageStatus? status}) => ChatMessage(
    id: id,
    conversationId: conversationId,
    sender: sender,
    body: body,
    createdAt: createdAt,
    status: status ?? this.status,
  );

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id']?.toString() ?? '',
    conversationId: json['conversationId']?.toString() ?? '',
    sender: json['sender'] is Map<String, dynamic>
        ? TvoiceUser.fromJson(json['sender'] as Map<String, dynamic>)
        : null,
    body: json['body']?.toString() ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
        DateTime.now(),
    status: MessageStatus.values.firstWhere(
      (value) => value.name == json['status'],
      orElse: () => MessageStatus.sent,
    ),
  );

  factory ChatMessage.fromPreview(
    Map<String, dynamic> json,
    String conversationId,
  ) => ChatMessage(
    id: json['id']?.toString() ?? '',
    conversationId: conversationId,
    body: json['body']?.toString() ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
        DateTime.now(),
  );
}

class ConferenceRoom {
  const ConferenceRoom({
    required this.id,
    required this.title,
    required this.inviteUrl,
    required this.createdAt,
    this.allowGuests = true,
    this.active = true,
  });

  final String id;
  final String title;
  final String inviteUrl;
  final DateTime createdAt;
  final bool allowGuests;
  final bool active;

  factory ConferenceRoom.fromJson(Map<String, dynamic> json) => ConferenceRoom(
    id: json['id']?.toString() ?? '',
    title: json['title']?.toString() ?? 'Конференция',
    inviteUrl: json['inviteUrl']?.toString() ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
        DateTime.now(),
    allowGuests: json['allowGuests'] == true,
    active: json['active'] != false && json['status']?.toString() != 'ended',
  );
}

class VideoCallSession {
  const VideoCallSession({
    required this.callId,
    required this.peer,
    this.url,
    this.token,
    this.incoming = false,
    this.conferenceId,
    this.title,
    this.role,
    this.inviteUrl,
    this.allowGuests = false,
    this.initialCamera = true,
    this.initialMicrophone = true,
  });

  final String callId;
  final TvoiceUser peer;
  final String? url;
  final String? token;
  final bool incoming;
  final String? conferenceId;
  final String? title;
  final String? role;
  final String? inviteUrl;
  final bool allowGuests;
  final bool initialCamera;
  final bool initialMicrophone;

  bool get isConferenceRoom => conferenceId != null;
  bool get isOrganizer => role == 'organizer';

  bool get isReady => url != null && token != null;

  factory VideoCallSession.outgoing(Map<String, dynamic> json) =>
      VideoCallSession(
        callId: json['callId']?.toString() ?? '',
        peer: TvoiceUser.fromJson(json['peer'] as Map<String, dynamic>),
        url: json['url']?.toString(),
        token: json['token']?.toString(),
      );

  factory VideoCallSession.incoming(Map<String, dynamic> json) =>
      VideoCallSession(
        callId: json['callId']?.toString() ?? '',
        peer: TvoiceUser.fromJson(json['from'] as Map<String, dynamic>),
        incoming: true,
      );

  VideoCallSession answered(Map<String, dynamic> json) => VideoCallSession(
    callId: callId,
    peer: peer,
    url: json['url']?.toString(),
    token: json['token']?.toString(),
    incoming: incoming,
  );

  factory VideoCallSession.conference(
    Map<String, dynamic> json,
    TvoiceUser localUser,
  ) => VideoCallSession(
    callId: json['id']?.toString() ?? '',
    conferenceId: json['id']?.toString(),
    title: json['title']?.toString(),
    role: json['role']?.toString(),
    inviteUrl: json['inviteUrl']?.toString(),
    allowGuests: json['allowGuests'] == true,
    initialCamera: json['initialCamera'] != false,
    initialMicrophone: json['initialMicrophone'] != false,
    peer: TvoiceUser(
      id: 'conference',
      sipNumber: '',
      displayName: json['title']?.toString() ?? 'Конференция',
    ),
    url: json['url']?.toString(),
    token: json['token']?.toString(),
  );
}

enum CallDirection { incoming, outgoing }

enum CallMedia { audio, video }

enum CallResult { completed, missed, failed }

class CallHistoryEntry {
  const CallHistoryEntry({
    required this.id,
    required this.number,
    required this.direction,
    required this.media,
    required this.result,
    required this.startedAt,
    this.connectedAt,
    this.endedAt,
  });

  final String id;
  final String number;
  final CallDirection direction;
  final CallMedia media;
  final CallResult result;
  final DateTime startedAt;
  final DateTime? connectedAt;
  final DateTime? endedAt;

  Duration get duration {
    final connected = connectedAt;
    if (connected == null) return Duration.zero;
    final value = (endedAt ?? DateTime.now()).difference(connected);
    return value.isNegative ? Duration.zero : value;
  }

  CallHistoryEntry copyWith({
    CallResult? result,
    DateTime? connectedAt,
    DateTime? endedAt,
  }) => CallHistoryEntry(
    id: id,
    number: number,
    direction: direction,
    media: media,
    result: result ?? this.result,
    startedAt: startedAt,
    connectedAt: connectedAt ?? this.connectedAt,
    endedAt: endedAt ?? this.endedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'number': number,
    'direction': direction.name,
    'media': media.name,
    'result': result.name,
    'startedAt': startedAt.toIso8601String(),
    'connectedAt': connectedAt?.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
  };

  factory CallHistoryEntry.fromJson(Map<String, dynamic> json) {
    T enumValue<T extends Enum>(List<T> values, dynamic raw, T fallback) =>
        values.where((value) => value.name == raw?.toString()).firstOrNull ??
        fallback;
    return CallHistoryEntry(
      id: json['id']?.toString() ?? '',
      number: json['number']?.toString() ?? '',
      direction: enumValue(
        CallDirection.values,
        json['direction'],
        CallDirection.outgoing,
      ),
      media: enumValue(CallMedia.values, json['media'], CallMedia.audio),
      result: enumValue(CallResult.values, json['result'], CallResult.failed),
      startedAt:
          DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
          DateTime.now(),
      connectedAt: DateTime.tryParse(json['connectedAt']?.toString() ?? ''),
      endedAt: DateTime.tryParse(json['endedAt']?.toString() ?? ''),
    );
  }
}
