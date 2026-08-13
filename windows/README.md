# Tvoice for Windows

Native Windows desktop client for the existing Tvoice service.

## Functions

The current Windows project contains a working WPF shell with:

- FreePBX-backed login through the Tvoice Chat API;
- synchronized Tvoice contacts;
- direct conversations and message history;
- live WebSocket messages and delivery/read events;
- account information and system light/dark theme selection;
- real SIP/UDP registration with Digest authentication, NAT `rport` mapping and
  periodic registration refresh;
- strict SIP message parsing and G.711 A-law/mu-law codec primitives;
- incoming and outgoing SIP calls through FreePBX;
- G.711 RTP audio, call timer, mute, hold and DTMF;
- incoming ringtone that stops immediately on answer or hangup;
- minimization to the Windows tray without interrupting an active call;
- incoming call notifications;
- LiveKit video calls with a portrait messenger-style window;
- movable self-preview, camera/microphone controls and camera switching;
- synchronized hangup for both video participants;
- photos and file attachments up to 20 MB;
- automatic Windows light/dark theme changes.

Passwords and access tokens are kept in process memory only.

## Build

Requirements:

- Windows 10 or 11 x64;
- .NET 8 SDK.

```powershell
dotnet restore windows\Tvoice.Windows\Tvoice.Windows.csproj
dotnet build windows\Tvoice.Windows\Tvoice.Windows.csproj -c Release
```

Run:

```powershell
dotnet run --project windows\Tvoice.Windows\Tvoice.Windows.csproj
```

The self-contained release can be produced with `windows/build-release.ps1`.
