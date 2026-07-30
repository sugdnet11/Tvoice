# Tvoice Chat client contract

The deployed service answers `GET /health` as `tvoice-chat` version `0.3.1`. The Android client uses:

- `POST /v1/auth/login` — obtain an access token from `sipNumber` and `password`;
- `GET /v1/contacts` — authenticated directory of chat-capable SIP subscribers;
- `GET /v1/conversations` and `POST /v1/conversations/direct`;
- `GET/POST /v1/conversations/{id}/messages`;
- `POST /v1/conversations/{id}/read` — advance delivered/read timestamps;
- `WSS /v1/ws?token=...` — live `message.new`, `message.delivered` and `message.read` events.

The Android login is unified with SIP. The chat server validates every login through the private
FreePBX bridge and synchronizes the directory at startup, every five minutes and after login.

## Client invariants

- Device phone formatting, `sip:` prefixes and domains are converted to one canonical SIP user key.
- Server contacts are merged with the optional Android phone book. Phone-book permission is not
  required to enter a SIP number or use the server directory.
- Message IDs are opaque strings. Numeric IDs and UUIDs are both supported.
- A local message is marked sent only after the server returns its message object; two light checks
  mean delivered and two dark checks mean read.
- HTTP 401 triggers one password-based token refresh and one retry of the original request.
- A failed text bubble keeps the server/network reason and can be tapped to retry using its unique
  local ID; repeated messages with identical text cannot update the wrong bubble.

File attachments are not part of the deployed `0.3.0` API. Never place credentials in this
repository or CI logs.
