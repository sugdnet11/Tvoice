# Tvoice architecture

## Dependency direction

```text
Activities / foreground service
        |
        v
TvoiceController -> TvoiceRuntime -> SipManager
                                      |
                                      v
                            TvoiceSipCore + RtpAudioSession

Repositories: AccountStore | CallHistoryStore | DeviceContactRepository | ChatStore
Transport:                                                ChatClient -> HTTPS/WSS API
```

Dependencies point from Android presentation and lifecycle components toward small contracts and
repositories. Protocol code does not reference activities or views. `TvoiceRuntime` is the sole
process-wide owner of the SIP engine, so closing or recreating an Activity does not close an active
socket or call.

## Responsibilities

- `MainActivity`, `IncomingCallActivity`: render state, request Android permissions and forward user
  actions. Call-history session rules and contacts queries are outside the Activity.
- `TvoiceController`: stable UI contract that can be replaced by a fake in UI tests.
- `TvoiceRuntime`: coordinates active account, SIP events, chat login, video surfaces and lifecycle observers.
- `SipManager`: stores the in-memory account set and switches the single active registration.
- `TvoiceSipCore`: serialized SIP transaction/dialog state on one worker; no UI dependencies.
- `RtpAudioSession`: negotiated G.711 audio, address/SSRC validation and Android audio routing.
- Stores/repositories: persistence and platform-provider access. SIP credentials, call history and
  chat messages are AES/GCM encrypted with separate non-exportable Android Keystore keys.
- `ChatClient`: authenticated HTTPS/WSS transport for the separately deployed chat service.
- `RtpVideoSession`: owns the dedicated H.264 RTP socket, RFC 6184 packetization, Camera2 capture,
  hardware MediaCodec encode/decode and replaceable UI preview/render surfaces.

## Invariants

1. There is one active SIP registration and at most one active call dialog per process.
2. A saved account is committed only after successful SIP registration. A rejected newly added
   account is removed and the previous account is restored.
3. The app accepts SIP only from the configured PBX address and audio only from the negotiated RTP
   address and pinned SSRC.
4. Network callbacks never keep an Activity reference. Observers are explicitly added/removed.
5. Release builds pass unit tests and lint before the signed artifact job can run.

## External boundaries

The PBX and Tvoice Chat server are separately deployed systems and are not present in this
repository. Conference calls, SIP/TLS and SRTP require matching server capabilities; they cannot be
implemented or verified solely by changing the Android client.
