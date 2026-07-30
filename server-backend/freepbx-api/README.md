# Tvoice FreePBX authentication bridge

This private endpoint is installed on the FreePBX host and is reachable only
from the chat-server address (`10.10.10.6`) or localhost. It never returns SIP
secrets. The chat server uses it to validate a login and synchronize the list
of extensions and display names.

Runtime secret: `/etc/tvoice-auth.key` (not stored in this repository).

Endpoints:

- `POST /tvoice-api/index.php?action=auth`
- `GET /tvoice-api/index.php?action=users`
