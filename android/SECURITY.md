# Security model

## Protected locally

- SIP credentials: AES/GCM envelope; key generated and retained by Android Keystore.
- Call history: separate encrypted store with one-time migration from legacy preferences.
- Chat cache: separate AES/GCM Keystore key; legacy plaintext preferences migrate once and are
  cleared after a successful encrypted write.
- Chat access token and plaintext password: memory only.
- Backups and device-to-device extraction: explicitly excluded for files, databases and preferences.
- Cleartext Android HTTP traffic: disabled; HTTPS trusts system certificate authorities only.
- Attachments: sanitized names, private cache directory, 20 MB streaming limits on both upload and
  download, and partial-file cleanup after any failed download.
- Chat responses and WebSocket events: bounded to 2 MB before JSON parsing.

## Protocol validation

- SIP parser caps datagrams, header count and line length; rejects invalid UTF-8, malformed start
  lines, invalid header names and conflicting `Content-Length` values.
- Digest header values reject CR/LF injection and quote backslashes/double quotes.
- SIP datagrams from addresses other than the configured PBX are discarded.
- RTP validates version, CSRC/extension/padding bounds and payload length. Playback also checks the
  negotiated media address, codec payload type and a pinned SSRC.
- H.264 video uses a separate bounded RTP socket with the same negotiated-address, payload-type and
  first-SSRC pinning. Camera capture requires Android runtime permission and a visible foreground
  call notification while capture continues outside the call screen.

## Known transport constraint

The configured PBX currently requires SIP over UDP and plain RTP. This means call metadata, audio
and video are not confidential on the network. Address/packet validation is defense in depth, not encryption.
Production confidentiality requires PBX-side SIP/TLS plus SRTP configuration, certificates and
end-to-end interoperability tests.

## Reporting

Do not open a public issue containing credentials, tokens, call recordings or subscriber data.
Share a minimal reproduction privately with the repository owner and rotate any exposed secret.
