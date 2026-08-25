"use client";

import {
  Camera,
  CameraOff,
  Maximize2,
  Mic,
  MicOff,
  PhoneOff,
  RefreshCw,
  Volume2,
  VolumeX,
} from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  LocalVideoTrack,
  Room,
  RoomEvent,
  Track,
  VideoPresets,
} from "livekit-client";
import type { CallDirection, CallKind, VideoCallCredentials } from "./lib/types";

type Props = {
  credentials: VideoCallCredentials;
  kind: CallKind;
  direction: CallDirection;
  peerAnswered: boolean;
  onEnd: (reason: "local" | "remote" | "failed", durationSeconds: number) => void;
};

function formatDuration(total: number) {
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  return [hours, minutes, seconds]
    .filter((_, index) => hours > 0 || index > 0)
    .map((value) => String(value).padStart(2, "0"))
    .join(":");
}

export function CallScreen({ credentials, kind, direction, peerAnswered, onEnd }: Props) {
  const roomRef = useRef<Room | null>(null);
  const localVideoRef = useRef<HTMLVideoElement>(null);
  const remoteVideoRef = useRef<HTMLVideoElement>(null);
  const remoteAudioRef = useRef<HTMLAudioElement>(null);
  const connectedAtRef = useRef<number | null>(null);
  const joinedRef = useRef(false);
  const endingRef = useRef(false);
  const [joined, setJoined] = useState(false);
  const [micEnabled, setMicEnabled] = useState(true);
  const [cameraEnabled, setCameraEnabled] = useState(kind === "video");
  const [speakerEnabled, setSpeakerEnabled] = useState(true);
  const [facingMode, setFacingMode] = useState<"user" | "environment">("user");
  const [duration, setDuration] = useState(0);
  const [error, setError] = useState("");
  const [previewOffset, setPreviewOffset] = useState({ x: 0, y: 0 });
  const dragRef = useRef<{ x: number; y: number; startX: number; startY: number } | null>(null);

  const attachLocalVideo = useCallback((room: Room) => {
    const publication = room.localParticipant.getTrackPublication(Track.Source.Camera);
    const element = localVideoRef.current;
    if (publication?.track && element) publication.track.attach(element);
  }, []);

  useEffect(() => {
    let cancelled = false;
    const room = new Room({
      adaptiveStream: true,
      dynacast: true,
      videoCaptureDefaults: {
        resolution: VideoPresets.h720.resolution,
        facingMode: "user",
      },
      publishDefaults: {
        simulcast: true,
        videoCodec: "vp8",
      },
    });
    roomRef.current = room;

    const markJoined = () => {
      if (cancelled) return;
      connectedAtRef.current ??= Date.now();
      joinedRef.current = true;
      setJoined(true);
    };

    room
      .on(RoomEvent.TrackSubscribed, (track) => {
        if (track.kind === Track.Kind.Video && remoteVideoRef.current) {
          track.attach(remoteVideoRef.current);
        }
        if (track.kind === Track.Kind.Audio && remoteAudioRef.current) {
          track.attach(remoteAudioRef.current);
        }
      })
      .on(RoomEvent.ParticipantConnected, markJoined)
      .on(RoomEvent.ParticipantDisconnected, () => {
        if (!endingRef.current) {
          const seconds = connectedAtRef.current
            ? Math.floor((Date.now() - connectedAtRef.current) / 1000)
            : 0;
          endingRef.current = true;
          onEnd("remote", seconds);
        }
      })
      .on(RoomEvent.Disconnected, () => {
        if (!endingRef.current && joinedRef.current) {
          const seconds = connectedAtRef.current
            ? Math.floor((Date.now() - connectedAtRef.current) / 1000)
            : 0;
          endingRef.current = true;
          onEnd("remote", seconds);
        }
      });

    (async () => {
      try {
        await room.connect(credentials.url, credentials.token, { autoSubscribe: true });
        await room.localParticipant.setMicrophoneEnabled(true);
        if (kind === "video") {
          await room.localParticipant.setCameraEnabled(true, {
            facingMode: "user",
            resolution: VideoPresets.h720.resolution,
          });
          attachLocalVideo(room);
        }
        if (room.remoteParticipants.size > 0) markJoined();
      } catch (cause) {
        if (cancelled) return;
        const message = cause instanceof Error ? cause.message : "Не удалось подключить звонок";
        setError(message);
      }
    })();

    return () => {
      cancelled = true;
      room.removeAllListeners();
      room.disconnect();
      roomRef.current = null;
    };
  }, [attachLocalVideo, credentials, kind, onEnd]);

  useEffect(() => {
    if (!joined) return;
    const timer = window.setInterval(() => {
      if (connectedAtRef.current) {
        setDuration(Math.floor((Date.now() - connectedAtRef.current) / 1000));
      }
    }, 1000);
    return () => window.clearInterval(timer);
  }, [joined]);

  const toggleMic = async () => {
    const next = !micEnabled;
    await roomRef.current?.localParticipant.setMicrophoneEnabled(next);
    setMicEnabled(next);
  };

  const toggleCamera = async () => {
    const next = !cameraEnabled;
    await roomRef.current?.localParticipant.setCameraEnabled(next, {
      facingMode,
      resolution: VideoPresets.h720.resolution,
    });
    setCameraEnabled(next);
    if (next && roomRef.current) window.setTimeout(() => attachLocalVideo(roomRef.current!), 50);
  };

  const switchCamera = async () => {
    const next = facingMode === "user" ? "environment" : "user";
    const publication = roomRef.current?.localParticipant.getTrackPublication(Track.Source.Camera);
    const track = publication?.track;
    if (track instanceof LocalVideoTrack) {
      await track.restartTrack({ facingMode: next, resolution: VideoPresets.h720.resolution });
      setFacingMode(next);
    }
  };

  const end = () => {
    if (endingRef.current) return;
    endingRef.current = true;
    onEnd("local", duration);
  };

  const pointerDown = (event: React.PointerEvent<HTMLDivElement>) => {
    event.currentTarget.setPointerCapture(event.pointerId);
    dragRef.current = {
      x: previewOffset.x,
      y: previewOffset.y,
      startX: event.clientX,
      startY: event.clientY,
    };
  };

  const pointerMove = (event: React.PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag) return;
    setPreviewOffset({
      x: drag.x + event.clientX - drag.startX,
      y: drag.y + event.clientY - drag.startY,
    });
  };

  const status = error
    ? "Ошибка подключения"
    : joined || peerAnswered
      ? formatDuration(duration)
      : direction === "incoming"
        ? "Подключение…"
        : "Вызов…";

  return (
    <div className={`call-screen ${kind === "audio" ? "audio-call" : "video-call"}`}>
      {/* Live calls do not have a prerecorded caption track. */}
      {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
      <video ref={remoteVideoRef} className="remote-video" autoPlay playsInline />
      {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
      <audio ref={remoteAudioRef} autoPlay muted={!speakerEnabled} />
      <div className="call-backdrop" />

      <header className="call-header">
        <div>
          <p>{kind === "video" ? "Видеозвонок Tvoice" : "Аудиозвонок Tvoice"}</p>
          <h2>{credentials.peer.displayName || credentials.peer.sipNumber}</h2>
          <span>{status}</span>
        </div>
        <button className="call-icon-button" aria-label="Полный экран" onClick={() => document.documentElement.requestFullscreen?.()}>
          <Maximize2 size={20} />
        </button>
      </header>

      {kind === "audio" && (
        <div className="audio-call-avatar" aria-hidden="true">
          {(credentials.peer.displayName || credentials.peer.sipNumber).slice(0, 1).toUpperCase()}
        </div>
      )}

      {kind === "video" && (
        <div
          className="local-preview"
          style={{ transform: `translate(${previewOffset.x}px, ${previewOffset.y}px)` }}
          onPointerDown={pointerDown}
          onPointerMove={pointerMove}
          onPointerUp={() => { dragRef.current = null; }}
          onPointerCancel={() => { dragRef.current = null; }}
          onKeyDown={(event) => {
            const step = event.shiftKey ? 20 : 8;
            if (event.key === "ArrowLeft") setPreviewOffset((value) => ({ ...value, x: value.x - step }));
            if (event.key === "ArrowRight") setPreviewOffset((value) => ({ ...value, x: value.x + step }));
            if (event.key === "ArrowUp") setPreviewOffset((value) => ({ ...value, y: value.y - step }));
            if (event.key === "ArrowDown") setPreviewOffset((value) => ({ ...value, y: value.y + step }));
          }}
          role="button"
          tabIndex={0}
          aria-label="Перемещаемое окно своей камеры"
        >
          <video ref={localVideoRef} autoPlay muted playsInline />
          {!cameraEnabled && <CameraOff size={24} />}
        </div>
      )}

      {error && <div className="call-error">{error}</div>}

      <div className="call-controls" aria-label="Управление звонком">
        <button className={!micEnabled ? "is-off" : ""} onClick={toggleMic} aria-label={micEnabled ? "Выключить микрофон" : "Включить микрофон"}>
          {micEnabled ? <Mic /> : <MicOff />}
        </button>
        {kind === "video" && (
          <button className={!cameraEnabled ? "is-off" : ""} onClick={toggleCamera} aria-label={cameraEnabled ? "Выключить камеру" : "Включить камеру"}>
            {cameraEnabled ? <Camera /> : <CameraOff />}
          </button>
        )}
        {kind === "video" && (
          <button onClick={switchCamera} disabled={!cameraEnabled} aria-label="Переключить камеру">
            <RefreshCw />
          </button>
        )}
        <button className={!speakerEnabled ? "is-off" : ""} onClick={() => setSpeakerEnabled((value) => !value)} aria-label="Динамик">
          {speakerEnabled ? <Volume2 /> : <VolumeX />}
        </button>
        <button className="end-call" onClick={end} aria-label="Завершить звонок">
          <PhoneOff />
        </button>
      </div>
    </div>
  );
}
