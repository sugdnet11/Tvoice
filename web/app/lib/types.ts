export type TvoiceUser = {
  id: string;
  sipNumber: string;
  displayName: string;
};

export type LoginResponse = {
  accessToken: string;
  expiresIn: number;
  user: TvoiceUser;
};

export type MessageStatus = "sending" | "sent" | "delivered" | "read" | "received" | "failed";

export type ChatAttachment = {
  id: string;
  name: string;
  mimeType: string;
  size: number;
};

export type ChatMessage = {
  id: string;
  conversationId?: string;
  sender: TvoiceUser;
  body: string;
  createdAt: string;
  status?: MessageStatus;
  attachment?: ChatAttachment | null;
};

export type Conversation = {
  id: string;
  peer: TvoiceUser;
  lastMessage?: {
    id: string;
    body: string;
    createdAt: string;
  } | null;
};

export type CallKind = "audio" | "video";
export type CallDirection = "incoming" | "outgoing";

export type VideoCallCredentials = {
  callId: string;
  room: string;
  url: string;
  token: string;
  peer: TvoiceUser;
  expiresAt?: string;
  delivered?: boolean;
  kind?: CallKind;
};

export type IncomingCall = {
  callId: string;
  from: TvoiceUser;
  expiresAt?: string;
  kind: CallKind;
};

export type CallHistoryEntry = {
  id: string;
  peer: TvoiceUser;
  kind: CallKind;
  direction: CallDirection;
  startedAt: string;
  durationSeconds: number;
  result: "completed" | "missed" | "rejected" | "failed";
};

export type RealtimeEvent = {
  type: string;
  user?: TvoiceUser;
  message?: ChatMessage;
  conversationId?: string;
  throughCreatedAt?: string;
  callId?: string;
  from?: TvoiceUser;
  reason?: string;
  expiresAt?: string;
  kind?: CallKind;
};

export type RuntimeConfig = {
  wsUrl: string;
  sipWssUrl: string;
  pushPublicKey: string;
};
