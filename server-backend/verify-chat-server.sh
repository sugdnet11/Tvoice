#!/bin/sh
set -eu

docker exec tvoice-chat-postgres-1 psql -U tvoice -d tvoice_chat -Atc \
  "SELECT COUNT(*), COUNT(*) FILTER (WHERE auth_source = 'freepbx'), COUNT(*) FILTER (WHERE is_active) FROM users"
docker logs --tail 50 tvoice-chat-chat-1 2>&1 | grep -E 'synchronized|failed|Server listening' || true
docker exec tvoice-chat-postgres-1 psql -U tvoice -d tvoice_chat -P pager=off -c \
  "SELECT m.id, sender.sip_number AS sender, m.created_at,
          member_user.sip_number AS member,
          cm.last_delivered_at, cm.last_read_at
   FROM messages m
   JOIN users sender ON sender.id = m.sender_id
   JOIN conversation_members cm ON cm.conversation_id = m.conversation_id
   JOIN users member_user ON member_user.id = cm.user_id
   WHERE m.body LIKE '[Tvoice system test]%'
   ORDER BY m.id, member_user.sip_number"
