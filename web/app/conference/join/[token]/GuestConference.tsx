'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import {
  LocalParticipant,
  Participant,
  RemoteAudioTrack,
  RemoteParticipant,
  Room,
  RoomEvent,
  Track,
  VideoTrack,
} from 'livekit-client';
import { Camera, CameraOff, Copy, LogOut, MessageSquare, Mic, MicOff, MonitorUp, Send, Volume2 } from 'lucide-react';
import './guest-conference.css';

type InviteInfo = {
  id: string;
  title: string;
  active: boolean;
  allowGuests: boolean;
  participantCount: number;
  maxParticipants: number;
};
type RoomMessage = { sender: string; text: string; mine: boolean };

function AudioOutput({ track }: { track: RemoteAudioTrack }) {
  const host = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (!host.current) return;
    const element = track.attach();
    element.autoplay = true;
    element.volume = 1;
    element.setAttribute('playsinline', '');
    host.current.replaceChildren(element);
    return () => {
      track.detach(element);
      element.remove();
    };
  }, [track]);

  return <span ref={host} className="guest-audio-output" aria-hidden="true" />;
}

function VideoTile({ participant, local }: { participant: Participant; local: boolean }) {
  const host = useRef<HTMLDivElement>(null);
  const publications = [...participant.videoTrackPublications.values()];
  const screen = publications.find((publication) =>
    publication.source === Track.Source.ScreenShare && publication.track)?.track as VideoTrack | undefined;
  const camera = screen || publications.find((publication) =>
    publication.source === Track.Source.Camera && publication.track)?.track as VideoTrack | undefined;
  const audioTracks = local ? [] : [...participant.audioTrackPublications.values()]
    .map((publication) => publication.track)
    .filter((track): track is RemoteAudioTrack => track instanceof RemoteAudioTrack);
  useEffect(() => {
    if (!camera || !host.current) return;
    const element = camera.attach();
    element.muted = local;
    element.style.objectFit = screen ? 'contain' : 'cover';
    if (screen) element.style.background = '#050a13';
    if (element instanceof HTMLVideoElement) element.playsInline = true;
    host.current.replaceChildren(element);
    return () => { camera.detach(element); };
  }, [camera, local, screen]);
  const name = local ? 'Вы' : participant.name || participant.identity;
  return (
    <article className={`guest-video-tile ${participant.isSpeaking ? 'is-speaking' : ''}`}>
      <div ref={host} className={`guest-video-host ${local && !screen ? 'is-local' : ''} ${screen ? 'is-screen' : ''}`} />
      {audioTracks.map((track) => <AudioOutput key={track.sid} track={track} />)}
      {!camera && <div className="guest-avatar">{name.slice(0, 1).toUpperCase()}</div>}
      <span className="guest-video-name">{name}</span>
    </article>
  );
}

export function GuestConference({ inviteToken }: { inviteToken: string }) {
  const room = useMemo(() => new Room({ adaptiveStream: true, dynacast: true }), []);
  const [invite, setInvite] = useState<InviteInfo | null>(null);
  const [name, setName] = useState('');
  const [error, setError] = useState('');
  const [joining, setJoining] = useState(false);
  const [connected, setConnected] = useState(false);
  const [participants, setParticipants] = useState<Participant[]>([]);
  const [mic, setMic] = useState(true);
  const [camera, setCamera] = useState(true);
  const [sharing, setSharing] = useState(false);
  const [audioBlocked, setAudioBlocked] = useState(false);
  const [chatOpen, setChatOpen] = useState(false);
  const [messages, setMessages] = useState<RoomMessage[]>([]);
  const [message, setMessage] = useState('');

  useEffect(() => {
    fetch(`/api/tvoice/conferences/invitations/${encodeURIComponent(inviteToken)}`, {
      cache: 'no-store',
      referrerPolicy: 'no-referrer',
    })
      .then(async (response) => {
        if (!response.ok) throw new Error('Ссылка недействительна или срок её действия истёк');
        return response.json();
      })
      .then((data) => setInvite(data.conference))
      .catch((reason: Error) => setError(reason.message));
  }, [inviteToken]);

  useEffect(() => {
    const refresh = () => setParticipants([
      ...(room.localParticipant ? [room.localParticipant] : []),
      ...room.remoteParticipants.values(),
    ]);
    const refreshAudioPlayback = () => setAudioBlocked(!room.canPlaybackAudio);
    room.on(RoomEvent.ParticipantConnected, refresh);
    room.on(RoomEvent.ParticipantDisconnected, refresh);
    room.on(RoomEvent.TrackSubscribed, refresh);
    room.on(RoomEvent.TrackUnsubscribed, refresh);
    room.on(RoomEvent.ActiveSpeakersChanged, refresh);
    room.on(RoomEvent.AudioPlaybackStatusChanged, refreshAudioPlayback);
    room.on(RoomEvent.DataReceived, (payload, participant, _kind, topic) => {
      if (topic !== 'tvoice.room.chat') return;
      try {
        const body = JSON.parse(new TextDecoder().decode(payload));
        if (typeof body.text === 'string' && body.text.trim()) {
          setMessages((current) => [...current, {
            sender: participant?.name || participant?.identity || 'Участник',
            text: body.text.trim(),
            mine: false,
          }]);
        }
      } catch { /* malformed room packet */ }
    });
    room.on(RoomEvent.Disconnected, () => setConnected(false));
    return () => {
      room.off(RoomEvent.AudioPlaybackStatusChanged, refreshAudioPlayback);
      void room.disconnect();
    };
  }, [room]);

  async function joinGuest() {
    if (!invite || name.trim().length < 2) return;
    setJoining(true);
    setError('');
    try {
      const response = await fetch(`/api/tvoice/conferences/invitations/${encodeURIComponent(inviteToken)}/guest-join`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ displayName: name.trim() }),
        referrerPolicy: 'no-referrer',
      });
      const data = await response.json();
      if (!response.ok) throw new Error('Не удалось войти в конференцию');
      await room.connect(data.conference.url, data.conference.token);
      try {
        await room.startAudio();
        setAudioBlocked(false);
      } catch {
        setAudioBlocked(true);
      }
      await Promise.all([
        room.localParticipant.setMicrophoneEnabled(true),
        room.localParticipant.setCameraEnabled(true),
      ]);
      setParticipants([room.localParticipant, ...room.remoteParticipants.values()]);
      setConnected(true);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Ошибка подключения');
    } finally {
      setJoining(false);
    }
  }

  async function enableAudio() {
    setError('');
    try {
      await room.startAudio();
      setAudioBlocked(!room.canPlaybackAudio);
    } catch {
      setAudioBlocked(true);
      setError('Браузер не разрешил воспроизведение звука. Нажмите кнопку ещё раз.');
    }
  }

  async function sendMessage() {
    const text = message.trim();
    if (!text) return;
    await room.localParticipant.publishData(
      new TextEncoder().encode(JSON.stringify({ text, sentAt: new Date().toISOString() })),
      { reliable: true, topic: 'tvoice.room.chat' },
    );
    setMessages((current) => [...current, { sender: 'Вы', text, mine: true }]);
    setMessage('');
  }

  if (!connected) return (
    <main className="guest-lobby">
      <section className="guest-lobby-card">
        <div className="guest-brand">Tvoice</div>
        <h1>{invite?.title || 'Конференция Tvoice'}</h1>
        <p>{invite ? `${invite.participantCount} из ${invite.maxParticipants} участников` : 'Проверяем приглашение…'}</p>
        {error && <p className="guest-error">{error}</p>}
        {invite?.active && invite.allowGuests && <>
          <label>Ваше имя<input value={name} maxLength={50} onChange={(event) => setName(event.target.value)} autoFocus /></label>
          <button disabled={joining || name.trim().length < 2} onClick={joinGuest}>{joining ? 'Подключение…' : 'Войти как гость'}</button>
          <a className="guest-open-app" href={`tvoice://conference/join?token=${encodeURIComponent(inviteToken)}`}>Открыть в Tvoice</a>
        </>}
      </section>
    </main>
  );

  return <main className="guest-room">
    <header><strong>{invite?.title}</strong><span>{participants.length} участников</span></header>
    {audioBlocked && <button type="button" className="guest-enable-audio" onClick={() => void enableAudio()}><Volume2 size={18} />Включить звук</button>}
    <section className="guest-room-body">
      <div className="guest-grid" data-count={participants.length}>
        {participants.map((participant) => <VideoTile key={participant.identity} participant={participant} local={participant instanceof LocalParticipant} />)}
      </div>
      <aside className={`guest-chat ${chatOpen ? 'is-open' : ''}`}>
        <h2>Чат комнаты<button type="button" onClick={() => setChatOpen(false)} aria-label="Закрыть чат">×</button></h2>
        <div className="guest-messages">{messages.map((item, index) => <div key={index} className={item.mine ? 'mine' : ''}><small>{item.sender}</small>{item.text}</div>)}</div>
        <form onSubmit={(event) => { event.preventDefault(); void sendMessage(); }}><input value={message} onChange={(event) => setMessage(event.target.value)} placeholder="Сообщение…" /><button aria-label="Отправить"><Send size={18} /></button></form>
      </aside>
    </section>
    <nav className="guest-controls">
      <button aria-label={mic ? 'Выключить микрофон' : 'Включить микрофон'} onClick={async () => { const next = !mic; await room.localParticipant.setMicrophoneEnabled(next); setMic(next); }}>{mic ? <Mic /> : <MicOff />}</button>
      <button aria-label={camera ? 'Выключить камеру' : 'Включить камеру'} onClick={async () => { const next = !camera; await room.localParticipant.setCameraEnabled(next); setCamera(next); }}>{camera ? <Camera /> : <CameraOff />}</button>
      <button aria-label="Демонстрация экрана" className={sharing ? 'active' : ''} onClick={async () => { const next = !sharing; await room.localParticipant.setScreenShareEnabled(next); setSharing(next); }}><MonitorUp /></button>
      <button aria-label="Чат" className={chatOpen ? 'active' : ''} onClick={() => setChatOpen((current) => !current)}><MessageSquare /></button>
      <button aria-label="Копировать ссылку" onClick={() => void navigator.clipboard.writeText(location.href)}><Copy /></button>
      <button aria-label="Выйти" className="danger" onClick={() => void room.disconnect()}><LogOut /></button>
    </nav>
  </main>;
}
