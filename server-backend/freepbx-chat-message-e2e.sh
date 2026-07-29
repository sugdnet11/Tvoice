#!/bin/sh
set -eu

CHAT_HOST=chat.185-177-2-115.sslip.io
RESOLVE="$CHAT_HOST:443:10.10.10.6"
BASE="https://$CHAT_HOST"
MESSAGE='[Tvoice system test] Chat delivery and read receipts verified on 2026-07-28.'

login() {
  extension="$1"
  secret=$(mysql -NBe "SELECT data FROM asterisk.sip WHERE id = '$extension' AND keyword = 'secret' LIMIT 1")
  test -n "$secret"
  payload=$(php -r 'echo json_encode(["sipNumber" => $argv[1], "password" => $argv[2]]);' "$extension" "$secret")
  response_file="/tmp/tvoice-login-$extension.json"
  status=$(curl -ksS --resolve "$RESOLVE" -o "$response_file" -w '%{http_code}' -H 'Content-Type: application/json' --data "$payload" "$BASE/v1/auth/login")
  test "$status" = 200
  php -r '$v=json_decode(file_get_contents($argv[1]), true); echo $v["accessToken"] ?? "";' "$response_file"
}

sender_token=$(login 73302)
recipient_token=$(login 77770)
test -n "$sender_token"
test -n "$recipient_token"

contacts_status=$(curl -ksS --resolve "$RESOLVE" -o /tmp/tvoice-contacts.json -w '%{http_code}' -H "Authorization: Bearer $sender_token" "$BASE/v1/contacts")
test "$contacts_status" = 200
contact_present=$(php -r '$v=json_decode(file_get_contents($argv[1]), true); foreach (($v["contacts"] ?? []) as $c) { if (($c["sipNumber"] ?? "") === "77770") { echo "yes"; exit; } } echo "no";' /tmp/tvoice-contacts.json)
test "$contact_present" = yes

conversation_status=$(curl -ksS --resolve "$RESOLVE" -o /tmp/tvoice-conversation.json -w '%{http_code}' -H "Authorization: Bearer $sender_token" -H 'Content-Type: application/json' --data '{"peerSipNumber":"77770"}' "$BASE/v1/conversations/direct")
test "$conversation_status" = 201
conversation_id=$(php -r '$v=json_decode(file_get_contents($argv[1]), true); echo $v["conversation"]["id"] ?? "";' /tmp/tvoice-conversation.json)
test -n "$conversation_id"

message_payload=$(php -r 'echo json_encode(["body" => $argv[1]], JSON_UNESCAPED_UNICODE);' "$MESSAGE")
send_status=$(curl -ksS --resolve "$RESOLVE" -o /tmp/tvoice-message-sent.json -w '%{http_code}' -H "Authorization: Bearer $sender_token" -H 'Content-Type: application/json' --data "$message_payload" "$BASE/v1/conversations/$conversation_id/messages")
test "$send_status" = 201

receive_status=$(curl -ksS --resolve "$RESOLVE" -o /tmp/tvoice-message-received.json -w '%{http_code}' -H "Authorization: Bearer $recipient_token" "$BASE/v1/conversations/$conversation_id/messages?limit=100")
test "$receive_status" = 200
received=$(php -r '$v=json_decode(file_get_contents($argv[1]), true); foreach (($v["messages"] ?? []) as $m) { if (($m["body"] ?? "") === $argv[2]) { echo "yes"; exit; } } echo "no";' /tmp/tvoice-message-received.json "$MESSAGE")
test "$received" = yes

read_http=$(curl -ksS --resolve "$RESOLVE" -o /tmp/tvoice-message-read.json -w '%{http_code}' -X POST -H "Authorization: Bearer $recipient_token" "$BASE/v1/conversations/$conversation_id/read")
test "$read_http" = 200

sender_messages_http=$(curl -ksS --resolve "$RESOLVE" -o /tmp/tvoice-sender-messages.json -w '%{http_code}' -H "Authorization: Bearer $sender_token" "$BASE/v1/conversations/$conversation_id/messages?limit=100")
test "$sender_messages_http" = 200
final_status=$(php -r '$v=json_decode(file_get_contents($argv[1]), true); foreach (($v["messages"] ?? []) as $m) { if (($m["body"] ?? "") === $argv[2]) { echo $m["status"] ?? "missing"; exit; } } echo "missing";' /tmp/tvoice-sender-messages.json "$MESSAGE")
test "$final_status" = read

echo "contacts_http=$contacts_status contact_77770=$contact_present conversation_http=$conversation_status send_http=$send_status receive_http=$receive_status received=$received read_http=$read_http final_status=$final_status"
