import type {
  ChatMessage,
  Conversation,
  LoginResponse,
  RuntimeConfig,
  TvoiceUser,
  VideoCallCredentials,
  CallKind,
} from "./types";

const API_ROOT = "/api/tvoice";

const friendlyErrors: Record<string, string> = {
  invalid_credentials: "Неверный номер или пароль.",
  invalid_request: "Проверьте введённые данные.",
  auth_provider_unavailable: "FreePBX временно недоступен.",
  unauthorized: "Сессия завершена. Войдите повторно.",
  contact_not_found: "Абонент не найден.",
  conversation_not_found: "Диалог не найден.",
  cannot_message_yourself: "Нельзя написать самому себе.",
  cannot_call_yourself: "Нельзя позвонить самому себе.",
  video_unavailable: "Сервер звонков временно недоступен.",
  call_not_found: "Звонок уже завершён.",
  file_too_large: "Файл больше 20 МБ.",
};

export class TvoiceApi {
  private token = "";

  setToken(token: string) {
    this.token = token;
  }

  clearToken() {
    this.token = "";
  }

  async login(sipNumber: string, password: string) {
    const result = await this.request<LoginResponse>("/auth/login", {
      method: "POST",
      body: JSON.stringify({ sipNumber: sipNumber.trim(), password }),
      headers: { "content-type": "application/json" },
      authenticated: false,
    });
    this.token = result.accessToken;
    return result;
  }

  getContacts() {
    return this.request<{ contacts: TvoiceUser[] }>("/contacts");
  }

  getConversations() {
    return this.request<{ conversations: Conversation[] }>("/conversations");
  }

  openConversation(peerSipNumber: string) {
    return this.request<{ conversation: Conversation }>("/conversations/direct", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ peerSipNumber }),
    });
  }

  getMessages(conversationId: string) {
    return this.request<{ messages: ChatMessage[] }>(
      `/conversations/${encodeURIComponent(conversationId)}/messages?limit=100`,
    );
  }

  sendMessage(conversationId: string, body: string) {
    return this.request<{ message: ChatMessage }>(
      `/conversations/${encodeURIComponent(conversationId)}/messages`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ body }),
      },
    );
  }

  uploadAttachment(conversationId: string, file: File) {
    const form = new FormData();
    form.append("file", file);
    return this.request<{ message: ChatMessage }>(
      `/conversations/${encodeURIComponent(conversationId)}/attachments`,
      { method: "POST", body: form },
    );
  }

  markRead(conversationId: string) {
    return this.request<{ readThrough: string | null }>(
      `/conversations/${encodeURIComponent(conversationId)}/read`,
      { method: "POST" },
    );
  }

  startCall(peerSipNumber: string, kind: CallKind) {
    return this.request<VideoCallCredentials>("/video/calls", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ peerSipNumber, kind }),
    });
  }

  answerCall(callId: string, kind: CallKind) {
    return this.request<VideoCallCredentials>(`/video/calls/${encodeURIComponent(callId)}/answer`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ kind }),
    });
  }

  finishCall(callId: string, action: "reject" | "end") {
    return this.request<void>(`/video/calls/${encodeURIComponent(callId)}/${action}`, {
      method: "POST",
    });
  }

  async downloadAttachment(id: string) {
    const response = await fetch(`${API_ROOT}/attachments/${encodeURIComponent(id)}`, {
      headers: { authorization: `Bearer ${this.token}` },
    });
    if (!response.ok) throw await this.toError(response);
    return response.blob();
  }

  async getRuntimeConfig() {
    const response = await fetch("/api/config", { cache: "no-store" });
    if (!response.ok) throw new Error("Не удалось загрузить конфигурацию Tvoice.");
    return (await response.json()) as RuntimeConfig;
  }

  private async request<T>(
    path: string,
    options: RequestInit & { authenticated?: boolean } = {},
  ): Promise<T> {
    const headers = new Headers(options.headers);
    if (options.authenticated !== false) {
      if (!this.token) throw new Error("Сначала войдите в аккаунт.");
      headers.set("authorization", `Bearer ${this.token}`);
    }
    headers.set("accept", "application/json");
    const response = await fetch(`${API_ROOT}${path}`, {
      ...options,
      headers,
      cache: "no-store",
    });
    if (!response.ok) throw await this.toError(response);
    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }

  private async toError(response: Response) {
    let code = "";
    try {
      code = String((await response.json() as { error?: string }).error || "");
    } catch {
      code = "";
    }
    return new Error(friendlyErrors[code] || `Ошибка сервера (${response.status}).`);
  }
}

export const tvoiceApi = new TvoiceApi();
