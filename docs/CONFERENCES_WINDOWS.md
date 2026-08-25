# Tvoice conference rooms (Windows and guest web)

## Components

- Windows/Desktop creates and joins rooms through the chat API and connects to the existing LiveKit deployment.
- The API stores rooms, hashed invite tokens, roles and memberships in PostgreSQL.
- The public route `/conference/join/<token>` provides authenticated app opening and browser guest entry.
- SIP audio calls, direct video calls and personal chat keep their existing routes and media path.

## Required server environment

```env
LIVEKIT_API_KEY=...
LIVEKIT_API_SECRET=...
LIVEKIT_WS_URL=wss://video.example.com
TVOICE_PUBLIC_MEETING_URL=https://chat.example.com
CONFERENCE_INVITE_TTL_HOURS=168
CONFERENCE_GUEST_SESSION_TTL_MINUTES=120
CONFERENCE_MAX_PARTICIPANTS=16
CONFERENCE_MAX_GUESTS=8
```

`LIVEKIT_API_SECRET` is server-only. Media tokens and invite tokens must not be logged or stored in browser local storage.

## API

- `POST /v1/conferences` — create a room (authenticated).
- `GET /v1/conferences/invitations/:inviteToken` — public safe invite information.
- `POST /v1/conferences/invitations/:inviteToken/join` — authenticated join.
- `POST /v1/conferences/invitations/:inviteToken/guest-join` — rate-limited guest join.
- `POST /v1/conferences/:conferenceId/end` — organizer-only end for everyone.

Apply `server-backend/db/005_conferences.sql` before deploying the new API. The API also performs an idempotent schema check at startup.

## Windows links

The installer registers `tvoice://conference/join?token=...` under the current user. The runner is single-instance: a link opened while Tvoice is running is delivered to the existing process. Signed-in users join immediately; the link remains pending while the login screen is shown.

## Media behavior

- Camera publishing uses adaptive stream, dynacast, simulcast and an up-to-1080p profile.
- Screen sharing uses the native Windows source selector and a 1080p/15 fps screen profile.
- Room chat uses reliable LiveKit data packets with topic `tvoice.room.chat`.
- Layout is deterministic for 1–16 participants, keeps the local user last and highlights the active speaker without reordering.
- Organizers can leave alone or end the room for everyone. Ending deletes the LiveKit room so all clients disconnect immediately.

## Reverse proxy and security

Publish the guest page and `/api/tvoice/` proxy on HTTPS. Keep guest join rate limiting enabled, retain no-referrer behavior, and add the production web origin to CORS only if the page and API are deployed on different origins. LiveKit UDP/TURN firewall configuration remains an external infrastructure requirement.
