"use client";

import Image from "next/image";
import {
  ArrowLeft,
  Bell,
  Check,
  CheckCheck,
  ChevronRight,
  Download,
  FileText,
  Info,
  LogOut,
  MessageCircle,
  Mic,
  MoreHorizontal,
  Paperclip,
  Phone,
  PhoneIncoming,
  PhoneMissed,
  PhoneOutgoing,
  Plus,
  Search,
  Send,
  Settings,
  UserRound,
  Users,
  Video,
  X,
} from "lucide-react";
import {
  FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { CallScreen } from "./CallScreen";
import { tvoiceApi } from "./lib/tvoice-api";
import type {
  CallHistoryEntry,
  CallKind,
  ChatMessage,
  Conversation,
  IncomingCall,
  LoginResponse,
  RealtimeEvent,
  TvoiceUser,
  VideoCallCredentials,
} from "./lib/types";

type Tab = "contacts" | "calls" | "chats" | "account";
type ActiveCall = {
  credentials: VideoCallCredentials;
  kind: CallKind;
  direction: "incoming" | "outgoing";
  peerAnswered: boolean;
};

const SESSION_KEY = "tvoice-web-session-v1";
const HISTORY_KEY = "tvoice-web-call-history-v1";

function initials(user: TvoiceUser) {
  return (user.displayName || user.sipNumber || "T").slice(0, 2).toUpperCase();
}

function timeLabel(value?: string) {
  if (!value) return "";
  const date = new Date(value);
  const today = new Date();
  if (date.toDateString() === today.toDateString()) {
    return date.toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
  }
  return date.toLocaleDateString("ru-RU", { day: "2-digit", month: "2-digit" });
}

function durationLabel(seconds: number) {
  if (!seconds) return "Не состоялся";
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return `${minutes}:${String(rest).padStart(2, "0")}`;
}

function MessageTicks({ status }: { status?: ChatMessage["status"] }) {
  if (status === "sending") return <span className="sending-dot">•••</span>;
  if (status === "failed") return <span className="message-failed">!</span>;
  if (status === "delivered" || status === "read") {
    return <CheckCheck size={15} className={status === "read" ? "ticks-read" : ""} />;
  }
  return <Check size={15} />;
}

function Avatar({ user, size = "normal" }: { user: TvoiceUser; size?: "small" | "normal" | "large" }) {
  return <div className={`avatar avatar-${size}`}>{initials(user)}</div>;
}

export default function TvoiceApp() {
  const [hydrated, setHydrated] = useState(false);
  const [session, setSession] = useState<LoginResponse | null>(null);
  const [loginNumber, setLoginNumber] = useState("");
  const [loginPassword, setLoginPassword] = useState("");
  const [loginBusy, setLoginBusy] = useState(false);
  const [error, setError] = useState("");
  const [tab, setTab] = useState<Tab>("chats");
  const [contacts, setContacts] = useState<TvoiceUser[]>([]);
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [activeConversation, setActiveConversation] = useState<Conversation | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [draft, setDraft] = useState("");
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(false);
  const [connection, setConnection] = useState<"connecting" | "online" | "offline">("offline");
  const [incomingCall, setIncomingCall] = useState<IncomingCall | null>(null);
  const [activeCall, setActiveCall] = useState<ActiveCall | null>(null);
  const [callHistory, setCallHistory] = useState<CallHistoryEntry[]>([]);
  const [newChatOpen, setNewChatOpen] = useState(false);
  const [manualNumber, setManualNumber] = useState("");
  const [installPrompt, setInstallPrompt] = useState<Event | null>(null);
  const [installMessage, setInstallMessage] = useState("");
  const [notificationState, setNotificationState] = useState("Не настроены");
  const activeConversationRef = useRef<Conversation | null>(null);
  const activeCallRef = useRef<ActiveCall | null>(null);
  const incomingCallRef = useRef<IncomingCall | null>(null);
  const reconnectTimerRef = useRef<number | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const messageEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    try {
      const stored = sessionStorage.getItem(SESSION_KEY);
      if (stored) {
        const restored = JSON.parse(stored) as LoginResponse;
        tvoiceApi.setToken(restored.accessToken);
        queueMicrotask(() => setSession(restored));
      }
      const history = localStorage.getItem(HISTORY_KEY);
      if (history) queueMicrotask(() => setCallHistory(JSON.parse(history) as CallHistoryEntry[]));
    } catch {
      sessionStorage.removeItem(SESSION_KEY);
    } finally {
      queueMicrotask(() => setHydrated(true));
    }
  }, []);

  useEffect(() => {
    activeConversationRef.current = activeConversation;
  }, [activeConversation]);

  useEffect(() => {
    activeCallRef.current = activeCall;
  }, [activeCall]);

  useEffect(() => {
    incomingCallRef.current = incomingCall;
  }, [incomingCall]);

  useEffect(() => {
    messageEndRef.current?.scrollIntoView({ block: "end" });
  }, [messages]);

  useEffect(() => {
    const handler = (event: Event) => {
      event.preventDefault();
      setInstallPrompt(event);
    };
    window.addEventListener("beforeinstallprompt", handler);
    if (window.matchMedia("(display-mode: standalone)").matches) {
      queueMicrotask(() => setInstallMessage("Tvoice установлен"));
    }
    queueMicrotask(() => setNotificationState(
        "Notification" in window && Notification.permission === "granted"
          ? "Разрешены"
          : "Не настроены",
      ));
    return () => window.removeEventListener("beforeinstallprompt", handler);
  }, []);

  const addHistory = useCallback((entry: Omit<CallHistoryEntry, "id" | "startedAt">) => {
    const next: CallHistoryEntry = {
      ...entry,
      id: crypto.randomUUID(),
      startedAt: new Date().toISOString(),
    };
    setCallHistory((current) => {
      const updated = [next, ...current].slice(0, 100);
      localStorage.setItem(HISTORY_KEY, JSON.stringify(updated));
      return updated;
    });
  }, []);

  const refreshConversations = useCallback(async () => {
    const result = await tvoiceApi.getConversations();
    setConversations(result.conversations);
  }, []);

  const loadMessages = useCallback(async (conversation: Conversation) => {
    const result = await tvoiceApi.getMessages(conversation.id);
    setMessages(result.messages);
    await tvoiceApi.markRead(conversation.id).catch(() => undefined);
  }, []);

  const refreshAll = useCallback(async () => {
    setLoading(true);
    try {
      const [contactResult, conversationResult] = await Promise.all([
        tvoiceApi.getContacts(),
        tvoiceApi.getConversations(),
      ]);
      setContacts(contactResult.contacts);
      setConversations(conversationResult.conversations);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Ошибка загрузки данных");
    } finally {
      setLoading(false);
    }
  }, []);

  const handleRemoteCallEnd = useCallback((reason: string) => {
    const current = activeCallRef.current;
    if (!current) return;
    addHistory({
      peer: current.credentials.peer,
      kind: current.kind,
      direction: current.direction,
      durationSeconds: 0,
      result: reason === "reject" || reason === "rejected" ? "rejected" : "completed",
    });
    setActiveCall(null);
  }, [addHistory]);

  const handleRealtime = useCallback((event: RealtimeEvent) => {
    if (event.type === "message.new" && event.message) {
      if (activeConversationRef.current?.id === event.message.conversationId) {
        setMessages((current) => current.some((item) => item.id === event.message!.id)
          ? current
          : [...current, { ...event.message!, status: "received" }]);
        void tvoiceApi.markRead(event.message.conversationId!).catch(() => undefined);
      }
      void refreshConversations();
      return;
    }
    if ((event.type === "message.delivered" || event.type === "message.read") && event.conversationId) {
      const threshold = event.throughCreatedAt ? new Date(event.throughCreatedAt).getTime() : Infinity;
      setMessages((current) => current.map((item) => {
        if (item.conversationId !== event.conversationId || new Date(item.createdAt).getTime() > threshold) return item;
        return { ...item, status: event.type === "message.read" ? "read" : "delivered" };
      }));
      return;
    }
    if (event.type === "video.call.incoming" && event.callId && event.from) {
      const incoming: IncomingCall = {
        callId: event.callId,
        from: event.from,
        expiresAt: event.expiresAt,
        kind: event.kind || "video",
      };
      setIncomingCall(incoming);
      if ("Notification" in window && Notification.permission === "granted" && document.hidden) {
        new Notification(`Входящий ${incoming.kind === "video" ? "видеозвонок" : "звонок"}`, {
          body: incoming.from.displayName || incoming.from.sipNumber,
          icon: "/tvoice-icon.png",
          tag: incoming.callId,
        });
      }
      return;
    }
    if (event.type === "video.call.answered" && event.callId === activeCallRef.current?.credentials.callId) {
      setActiveCall((current) => current ? { ...current, peerAnswered: true } : null);
      return;
    }
    if (["video.call.ended", "video.call.rejected"].includes(event.type)) {
      if (event.callId === incomingCallRef.current?.callId) setIncomingCall(null);
      if (event.callId === activeCallRef.current?.credentials.callId) {
        handleRemoteCallEnd(event.type.endsWith("rejected") ? "rejected" : event.reason || "remote");
      }
    }
  }, [handleRemoteCallEnd, refreshConversations]);

  useEffect(() => {
    if (!session) return;
    let stopped = false;
    let socket: WebSocket | null = null;

    const connect = async () => {
      if (stopped) return;
      setConnection("connecting");
      try {
        const config = await tvoiceApi.getRuntimeConfig();
        const separator = config.wsUrl.includes("?") ? "&" : "?";
        socket = new WebSocket(`${config.wsUrl}${separator}token=${encodeURIComponent(session.accessToken)}`);
        socket.onopen = () => setConnection("online");
        socket.onmessage = (message) => {
          if (message.data === "pong") return;
          try { handleRealtime(JSON.parse(String(message.data)) as RealtimeEvent); } catch { /* ignore malformed event */ }
        };
        socket.onclose = () => {
          if (stopped) return;
          setConnection("offline");
          reconnectTimerRef.current = window.setTimeout(connect, 3000);
        };
        socket.onerror = () => socket?.close();
      } catch {
        setConnection("offline");
        reconnectTimerRef.current = window.setTimeout(connect, 5000);
      }
    };

    queueMicrotask(() => {
      void refreshAll();
      void connect();
    });
    return () => {
      stopped = true;
      if (reconnectTimerRef.current) window.clearTimeout(reconnectTimerRef.current);
      socket?.close(1000, "logout");
    };
  }, [handleRealtime, refreshAll, session]);

  const login = async (event: FormEvent) => {
    event.preventDefault();
    if (!loginNumber.trim() || !loginPassword) {
      setError("Введите номер абонента и пароль.");
      return;
    }
    setLoginBusy(true);
    setError("");
    try {
      const result = await tvoiceApi.login(loginNumber, loginPassword);
      sessionStorage.setItem(SESSION_KEY, JSON.stringify(result));
      setSession(result);
      setLoginPassword("");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Не удалось войти");
    } finally {
      setLoginBusy(false);
    }
  };

  const logout = () => {
    sessionStorage.removeItem(SESSION_KEY);
    tvoiceApi.clearToken();
    setSession(null);
    setContacts([]);
    setConversations([]);
    setMessages([]);
    setActiveConversation(null);
    setConnection("offline");
  };

  const openConversation = async (conversation: Conversation) => {
    setActiveConversation(conversation);
    setMessages([]);
    setTab("chats");
    setLoading(true);
    try {
      await loadMessages(conversation);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Не удалось открыть чат");
    } finally {
      setLoading(false);
    }
  };

  const openContactChat = async (contact: TvoiceUser) => {
    setNewChatOpen(false);
    setLoading(true);
    try {
      const result = await tvoiceApi.openConversation(contact.sipNumber);
      setConversations((current) => [
        result.conversation,
        ...current.filter((item) => item.id !== result.conversation.id),
      ]);
      await openConversation(result.conversation);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Не удалось создать диалог");
    } finally {
      setLoading(false);
    }
  };

  const sendMessage = async (event: FormEvent) => {
    event.preventDefault();
    const conversation = activeConversation;
    const text = draft.trim();
    if (!conversation || !text || !session) return;
    const temporaryId = `local-${Date.now()}`;
    const pending: ChatMessage = {
      id: temporaryId,
      conversationId: conversation.id,
      sender: session.user,
      body: text,
      createdAt: new Date().toISOString(),
      status: "sending",
    };
    setDraft("");
    setMessages((current) => [...current, pending]);
    try {
      const result = await tvoiceApi.sendMessage(conversation.id, text);
      setMessages((current) => current.map((item) => item.id === temporaryId ? result.message : item));
      void refreshConversations();
    } catch (cause) {
      setMessages((current) => current.map((item) => item.id === temporaryId ? { ...item, status: "failed" } : item));
      setError(cause instanceof Error ? cause.message : "Сообщение не отправлено");
    }
  };

  const uploadFile = async (file?: File) => {
    if (!file || !activeConversation || !session) return;
    if (file.size > 20 * 1024 * 1024) {
      setError("Файл больше 20 МБ.");
      return;
    }
    const temporaryId = `upload-${Date.now()}`;
    setMessages((current) => [...current, {
      id: temporaryId,
      conversationId: activeConversation.id,
      sender: session.user,
      body: "",
      createdAt: new Date().toISOString(),
      status: "sending",
      attachment: { id: "", name: file.name, mimeType: file.type, size: file.size },
    }]);
    try {
      const result = await tvoiceApi.uploadAttachment(activeConversation.id, file);
      setMessages((current) => current.map((item) => item.id === temporaryId ? result.message : item));
      void refreshConversations();
    } catch (cause) {
      setMessages((current) => current.map((item) => item.id === temporaryId ? { ...item, status: "failed" } : item));
      setError(cause instanceof Error ? cause.message : "Файл не отправлен");
    }
  };

  const downloadAttachment = async (message: ChatMessage) => {
    if (!message.attachment?.id) return;
    try {
      const blob = await tvoiceApi.downloadAttachment(message.attachment.id);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = message.attachment.name;
      anchor.click();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Файл не загрузился");
    }
  };

  const startCall = async (peer: TvoiceUser, kind: CallKind) => {
    setError("");
    try {
      const credentials = await tvoiceApi.startCall(peer.sipNumber, kind);
      if (credentials.delivered === false) throw new Error("Абонент сейчас не подключён.");
      const next: ActiveCall = {
        credentials: { ...credentials, kind },
        kind,
        direction: "outgoing",
        peerAnswered: false,
      };
      activeCallRef.current = next;
      setActiveCall(next);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Звонок не выполнен");
      addHistory({ peer, kind, direction: "outgoing", durationSeconds: 0, result: "failed" });
    }
  };

  const answerIncoming = async (kind: CallKind) => {
    const incoming = incomingCall;
    if (!incoming) return;
    try {
      const credentials = await tvoiceApi.answerCall(incoming.callId, kind);
      const next: ActiveCall = {
        credentials: { ...credentials, kind },
        kind,
        direction: "incoming",
        peerAnswered: true,
      };
      activeCallRef.current = next;
      setActiveCall(next);
      setIncomingCall(null);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Не удалось принять звонок");
      setIncomingCall(null);
    }
  };

  const rejectIncoming = async () => {
    const incoming = incomingCall;
    if (!incoming) return;
    setIncomingCall(null);
    await tvoiceApi.finishCall(incoming.callId, "reject").catch(() => undefined);
    addHistory({
      peer: incoming.from,
      kind: incoming.kind,
      direction: "incoming",
      durationSeconds: 0,
      result: "rejected",
    });
  };

  const finishActiveCall = useCallback((reason: "local" | "remote" | "failed", seconds: number) => {
    const current = activeCallRef.current;
    if (!current) return;
    activeCallRef.current = null;
    setActiveCall(null);
    if (reason === "local") void tvoiceApi.finishCall(current.credentials.callId, "end").catch(() => undefined);
    addHistory({
      peer: current.credentials.peer,
      kind: current.kind,
      direction: current.direction,
      durationSeconds: seconds,
      result: reason === "failed" ? "failed" : "completed",
    });
  }, [addHistory]);

  const install = async () => {
    if (window.matchMedia("(display-mode: standalone)").matches) {
      setInstallMessage("Tvoice уже установлен");
      return;
    }
    if (installPrompt && "prompt" in installPrompt) {
      await (installPrompt as Event & { prompt: () => Promise<void> }).prompt();
      setInstallPrompt(null);
      setInstallMessage("Установка предложена");
      return;
    }
    setInstallMessage("На iPhone: Поделиться → На экран «Домой»");
  };

  const enableNotifications = async () => {
    if (!("Notification" in window) || !("serviceWorker" in navigator)) {
      setNotificationState("Не поддерживаются");
      return;
    }
    const permission = await Notification.requestPermission();
    if (permission !== "granted") {
      setNotificationState("Запрещены");
      return;
    }
    setNotificationState("Разрешены");
    const registration = await navigator.serviceWorker.ready;
    const config = await tvoiceApi.getRuntimeConfig();
    if (config.pushPublicKey) {
      const bytes = Uint8Array.from(
        atob(config.pushPublicKey.replace(/-/g, "+").replace(/_/g, "/")),
        (character) => character.charCodeAt(0),
      );
      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: bytes,
      });
      await fetch("/api/tvoice/push/subscriptions", {
        method: "POST",
        headers: {
          authorization: `Bearer ${session?.accessToken || ""}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(subscription),
      }).catch(() => undefined);
    }
  };

  const filteredContacts = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return contacts;
    return contacts.filter((item) =>
      item.sipNumber.includes(query) || item.displayName.toLowerCase().includes(query));
  }, [contacts, search]);

  const filteredConversations = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return conversations;
    return conversations.filter((item) =>
      item.peer.sipNumber.includes(query) || item.peer.displayName.toLowerCase().includes(query));
  }, [conversations, search]);

  if (!hydrated) return <div className="app-loading"><Image src="/tvoice-icon.png" width={88} height={88} alt="Tvoice" priority /></div>;

  if (!session) {
    return (
      <main className="login-page">
        <section className="brand-panel" aria-label="Tvoice">
          <div className="brand-lockup">
            <Image className="brand-icon" src="/tvoice-icon.png" width={104} height={104} priority alt="Логотип Tvoice" />
            <div>
              <p className="eyebrow">TOJIKTELECOM</p>
              <h1>Tvoice</h1>
              <p className="brand-copy">Звонки, видеосвязь и сообщения между абонентами — прямо в браузере.</p>
            </div>
          </div>
          <div className="feature-row" aria-label="Возможности">
            <span>Защищённый чат</span><span>HD-видеозвонки</span><span>Единый SIP-вход</span>
          </div>
        </section>
        <section className="login-panel">
          <div className="login-card">
            <div className="mobile-brand"><Image src="/tvoice-icon.png" width={64} height={64} alt="" /><strong>Tvoice</strong></div>
            <p className="eyebrow">ДОБРО ПОЖАЛОВАТЬ</p>
            <h2>Войти в Tvoice</h2>
            <p className="muted">Используйте логин и пароль вашего SIP-аккаунта.</p>
            <form className="login-form" onSubmit={login}>
              <label>Номер абонента<input value={loginNumber} onChange={(event) => setLoginNumber(event.target.value.replace(/[^0-9*#+]/g, ""))} inputMode="tel" autoComplete="username" placeholder="Например, 73302" /></label>
              <label>Пароль<input value={loginPassword} onChange={(event) => setLoginPassword(event.target.value)} type="password" autoComplete="current-password" placeholder="Введите пароль" /></label>
              {error && <p className="form-error">{error}</p>}
              <button type="submit" disabled={loginBusy}>{loginBusy ? "Подключение…" : "Продолжить"}</button>
            </form>
            <div className="secure-note"><span className="status-dot" />Подключение к Tvoice защищено</div>
          </div>
        </section>
      </main>
    );
  }

  const title = tab === "contacts" ? "Контакты" : tab === "calls" ? "Звонки" : tab === "chats" ? "Чаты" : "Аккаунт";
  const showSearch = tab === "contacts" || tab === "chats";

  return (
    <main className="tvoice-shell">
      <aside className="desktop-sidebar">
        <div className="sidebar-brand"><Image src="/tvoice-icon.png" width={46} height={46} alt="" /><strong>Tvoice</strong></div>
        <nav>
          <button className={tab === "contacts" ? "active" : ""} onClick={() => { setTab("contacts"); setActiveConversation(null); }}><Users />Контакты</button>
          <button className={tab === "calls" ? "active" : ""} onClick={() => { setTab("calls"); setActiveConversation(null); }}><Phone />Звонки</button>
          <button className={tab === "chats" ? "active" : ""} onClick={() => { setTab("chats"); setActiveConversation(null); }}><MessageCircle />Чаты</button>
          <button className={tab === "account" ? "active" : ""} onClick={() => { setTab("account"); setActiveConversation(null); }}><UserRound />Аккаунт</button>
        </nav>
        <div className="sidebar-profile"><Avatar user={session.user} size="small" /><div><strong>{session.user.displayName}</strong><span>{session.user.sipNumber}</span></div><span className={`connection-dot ${connection}`} /></div>
      </aside>

      <section className={`app-content ${activeConversation ? "conversation-open" : ""}`}>
        {activeConversation ? (
          <div className="chat-view">
            <header className="chat-header">
              <button className="icon-button back-button" onClick={() => setActiveConversation(null)} aria-label="Назад"><ArrowLeft /></button>
              <Avatar user={activeConversation.peer} size="small" />
              <div className="chat-peer"><strong>{activeConversation.peer.displayName}</strong><span>{activeConversation.peer.sipNumber} · {connection === "online" ? "онлайн" : "нет соединения"}</span></div>
              <button className="icon-button" onClick={() => startCall(activeConversation.peer, "audio")} aria-label="Аудиозвонок"><Phone /></button>
              <button className="icon-button" onClick={() => startCall(activeConversation.peer, "video")} aria-label="Видеозвонок"><Video /></button>
              <button className="icon-button more-button" aria-label="Ещё"><MoreHorizontal /></button>
            </header>
            <div className="messages" aria-live="polite">
              {loading && messages.length === 0 && <div className="empty-inline">Загружаем сообщения…</div>}
              {!loading && messages.length === 0 && <div className="empty-inline"><MessageCircle size={34} /><strong>Начните общение</strong><span>Сообщения доступны на всех подключённых устройствах.</span></div>}
              {messages.map((message) => {
                const outgoing = message.sender.id === session.user.id;
                return (
                  <div key={message.id} className={`message-row ${outgoing ? "outgoing" : "incoming"}`}>
                    <div className="message-bubble">
                      {message.attachment && (
                        <button className="attachment" onClick={() => downloadAttachment(message)} disabled={!message.attachment.id}>
                          <FileText /><span><strong>{message.attachment.name}</strong><small>{Math.max(1, Math.round(message.attachment.size / 1024))} КБ</small></span><Download size={18} />
                        </button>
                      )}
                      {message.body && <p>{message.body}</p>}
                      <span className="message-meta">{timeLabel(message.createdAt)}{outgoing && <MessageTicks status={message.status} />}</span>
                    </div>
                  </div>
                );
              })}
              <div ref={messageEndRef} />
            </div>
            <form className="composer" onSubmit={sendMessage}>
              <input ref={fileInputRef} hidden type="file" onChange={(event) => { void uploadFile(event.target.files?.[0]); event.currentTarget.value = ""; }} />
              <button type="button" className="icon-button" onClick={() => fileInputRef.current?.click()} aria-label="Прикрепить файл"><Paperclip /></button>
              <textarea value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} placeholder="Сообщение" rows={1} maxLength={4000} />
              <button type="submit" className="send-button" disabled={!draft.trim()} aria-label="Отправить"><Send /></button>
            </form>
          </div>
        ) : (
          <>
            <header className="page-header">
              <div><p className="eyebrow">TVOICE</p><h1>{title}</h1></div>
              <div className="header-actions">
                <span className={`connection-badge ${connection}`}><span />{connection === "online" ? "Подключено" : connection === "connecting" ? "Подключение…" : "Нет соединения"}</span>
                {(tab === "contacts" || tab === "chats") && <button className="primary-small" onClick={() => setNewChatOpen(true)}><Plus />Новый чат</button>}
              </div>
            </header>
            {error && <div className="global-error"><Info /><span>{error}</span><button onClick={() => setError("")} aria-label="Закрыть"><X /></button></div>}
            {showSearch && <label className="search-field"><Search /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder={tab === "contacts" ? "Поиск контактов" : "Поиск чатов"} /></label>}

            {tab === "contacts" && <div className="content-list">{filteredContacts.map((contact) => <article className="contact-row" key={contact.id}><button className="contact-main" onClick={() => openContactChat(contact)}><Avatar user={contact} /><span><strong>{contact.displayName}</strong><small>{contact.sipNumber}</small></span></button><div className="row-actions"><button onClick={() => startCall(contact, "audio")} aria-label={`Позвонить ${contact.displayName}`}><Phone /></button><button onClick={() => startCall(contact, "video")} aria-label={`Видеозвонок ${contact.displayName}`}><Video /></button><button onClick={() => openContactChat(contact)} aria-label={`Написать ${contact.displayName}`}><MessageCircle /></button></div></article>)}{!loading && filteredContacts.length === 0 && <EmptyState icon={<Users />} title="Контактов пока нет" text="Абоненты FreePBX появятся здесь после синхронизации." />}</div>}

            {tab === "chats" && <div className="content-list conversation-list">{filteredConversations.map((conversation) => <button className="conversation-row" key={conversation.id} onClick={() => openConversation(conversation)}><Avatar user={conversation.peer} /><span className="conversation-copy"><strong>{conversation.peer.displayName}</strong><small>{conversation.lastMessage?.body || `Абонент ${conversation.peer.sipNumber}`}</small></span><span className="conversation-time">{timeLabel(conversation.lastMessage?.createdAt)}</span><ChevronRight /></button>)}{!loading && filteredConversations.length === 0 && <EmptyState icon={<MessageCircle />} title="Сообщений пока нет" text="Начните чат с абонентом Tvoice." action={<button onClick={() => setNewChatOpen(true)}>Начать чат</button>} />}</div>}

            {tab === "calls" && <div className="content-list">{callHistory.map((call) => <article className="call-row" key={call.id}><div className={`call-kind ${call.result === "missed" || call.result === "failed" ? "missed" : ""}`}>{call.direction === "incoming" ? (call.result === "missed" ? <PhoneMissed /> : <PhoneIncoming />) : <PhoneOutgoing />}</div><div className="call-copy"><strong>{call.peer.displayName || call.peer.sipNumber}</strong><small>{call.kind === "video" ? "Видеозвонок" : "Аудиозвонок"} · {timeLabel(call.startedAt)} · {durationLabel(call.durationSeconds)}</small></div><button onClick={() => startCall(call.peer, call.kind)} aria-label="Позвонить снова">{call.kind === "video" ? <Video /> : <Phone />}</button></article>)}{callHistory.length === 0 && <EmptyState icon={<Phone />} title="История звонков пуста" text="Здесь будут отображаться аудио- и видеозвонки с этого устройства." />}</div>}

            {tab === "account" && <div className="account-grid"><section className="account-card profile-card"><Avatar user={session.user} size="large" /><div><h2>{session.user.displayName}</h2><p>{session.user.sipNumber}</p><span className={`account-status ${connection}`}>{connection === "online" ? "Чат подключён" : "Подключение…"}</span></div></section><section className="account-card settings-card"><h3>Приложение</h3><button onClick={install}><Download /><span><strong>Установить Tvoice</strong><small>{installMessage || "Добавить на главный экран"}</small></span><ChevronRight /></button><button onClick={enableNotifications}><Bell /><span><strong>Уведомления</strong><small>{notificationState}</small></span><ChevronRight /></button><button><Settings /><span><strong>Оформление</strong><small>Системная тема</small></span><ChevronRight /></button></section><section className="account-card connection-card"><h3>Подключения</h3><div><MessageCircle /><span><strong>Чат</strong><small>chat.185-177-2-115.sslip.io</small></span><b className={connection}>{connection === "online" ? "Работает" : "Ожидание"}</b></div><div><Video /><span><strong>Видео</strong><small>LiveKit WebRTC</small></span><b className="online">Готово</b></div><div><Phone /><span><strong>SIP WebRTC</strong><small>Требуется WSS на FreePBX</small></span><b className="warning">Настройка</b></div></section><button className="logout-button" onClick={logout}><LogOut />Выйти из аккаунта</button></div>}
          </>
        )}
      </section>

      {!activeConversation && <nav className="mobile-nav"><button className={tab === "contacts" ? "active" : ""} onClick={() => setTab("contacts")}><Users /><span>Контакты</span></button><button className={tab === "calls" ? "active" : ""} onClick={() => setTab("calls")}><Phone /><span>Звонки</span></button><button className={tab === "chats" ? "active" : ""} onClick={() => setTab("chats")}><MessageCircle /><span>Чаты</span></button><button className={tab === "account" ? "active" : ""} onClick={() => setTab("account")}><UserRound /><span>Аккаунт</span></button></nav>}

      {newChatOpen && <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setNewChatOpen(false); }}><div className="new-chat-modal"><header><div><p className="eyebrow">НОВЫЙ ДИАЛОГ</p><h2>Выберите абонента</h2></div><button className="icon-button" onClick={() => setNewChatOpen(false)}><X /></button></header><form onSubmit={(event) => { event.preventDefault(); const found = contacts.find((item) => item.sipNumber === manualNumber); if (found) void openContactChat(found); else setError("Абонент не найден в контактах."); }}><label className="search-field"><Search /><input value={manualNumber} onChange={(event) => setManualNumber(event.target.value.replace(/[^0-9*#+]/g, ""))} placeholder="Введите SIP-номер" /></label></form><div className="modal-contacts">{contacts.map((contact) => <button key={contact.id} onClick={() => openContactChat(contact)}><Avatar user={contact} size="small" /><span><strong>{contact.displayName}</strong><small>{contact.sipNumber}</small></span><ChevronRight /></button>)}</div></div></div>}

      {incomingCall && !activeCall && <div className="incoming-call"><div className="incoming-card"><p>{incomingCall.kind === "video" ? "Входящий видеозвонок" : "Входящий звонок"}</p><Avatar user={incomingCall.from} size="large" /><h2>{incomingCall.from.displayName}</h2><span>{incomingCall.from.sipNumber}</span><div className="incoming-actions"><button className="reject" onClick={rejectIncoming}><PhoneMissed /></button><button className="answer-audio" onClick={() => answerIncoming("audio")}><Mic /></button><button className="answer-video" onClick={() => answerIncoming("video")}><Video /></button></div><small>Отклонить · Ответить голосом · Ответить с видео</small></div></div>}

      {activeCall && <CallScreen credentials={activeCall.credentials} kind={activeCall.kind} direction={activeCall.direction} peerAnswered={activeCall.peerAnswered} onEnd={finishActiveCall} />}
    </main>
  );
}

function EmptyState({ icon, title, text, action }: { icon: React.ReactNode; title: string; text: string; action?: React.ReactNode }) {
  return <div className="empty-state"><div>{icon}</div><h2>{title}</h2><p>{text}</p>{action}</div>;
}
