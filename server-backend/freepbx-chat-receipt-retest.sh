#!/bin/sh
set -eu

CHAT_HOST=chat.185-177-2-115.sslip.io
RESOLVE="$CHAT_HOST:443:10.10.10.6"
BASE="https://$CHAT_HOST"

login() {
  extension="$1"
  secret=$(mysql -NBe "SELECT data FROM asterisk.sip WHERE id = '$extension' AND keyword = 'secret' LIMIT 1")
  payload=$(php -r 'echo json_encode(["sipNumber" => $argv[1], "password" => $argv[2]]);' "$extension" "$secret")
  response_file="/tmp/tvoice-retest-login-$extension.json"
  status=$(curl -ksS --resolve "$RESOLVE" -o "$response_file" -w '%{http_code}' -H 'Content-Type: application/json' --data "$payload" "$BASE/v1/auth/login")
  test "$status" = 200
  php -r '$v=json_decode(file_get_contents($argv[1]), true); echo $v["accessToken"] ?? "";' "$response_file"
}

sender_token=$(login 73302)
recipient_token=$(login 77770)
conversation_http=$(curl -ksS --resolve "$RESOLVE" -o /tmp/tvoice-retest-conversation.json -w '%{http_code}' -H "Authorization: Bearer $sender_token" -H 'Content-Type: application/json' --data '{"peerSipNumber":"77770"}' "$BASE/v1/conversations/direct")
test "$conversation_http" = 201
conversation_id=$(php -r '$v=json_decode(file_get_contents($argv[1]), true); echo $v["conversation"]["id"] ?? "";' /tmp/tvoice-retest-conversation.json)
test -n "$conversation_id"

read_http=$(curl -ksS --resolve "$RESOLVE" -o /tmp/tvoice-retest-read.json -w '%{http_code}' -X POST -H "Authorization: Bearer $recipient_token" "$BASE/v1/conversations/$conversation_id/read")
test "$read_http" = 200
sender_http=$(curl -ksS --resolve "$RESOLVE" -o /tmp/tvoice-retest-sender.json -w '%{http_code}' -H "Authorization: Bearer $sender_token" "$BASE/v1/conversations/$conversation_id/messages?limit=100")
test "$sender_http" = 200
final_status=$(php -r '$v=json_decode(file_get_contents($argv[1]), true); $status="missing"; foreach (($v["messages"] ?? []) as $m) { if (str_starts_with($m["body"] ?? "", "[Tvoice system test]")) { $status=$m["status"] ?? "missing"; } } echo $status;' /tmp/tvoice-retest-sender.json)
test "$final_status" = read
echo "conversation_http=$conversation_http read_http=$read_http sender_messages_http=$sender_http final_status=$final_status"
