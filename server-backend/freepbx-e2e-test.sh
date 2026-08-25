#!/bin/sh
set -eu

sip_secret=$(mysql -NBe "SELECT data FROM asterisk.sip WHERE id = '73302' AND keyword = 'secret' LIMIT 1")
test -n "$sip_secret"
payload=$(php -r 'echo json_encode(["sipNumber" => $argv[1], "password" => $argv[2]], JSON_UNESCAPED_UNICODE);' 73302 "$sip_secret")

resolve='chat.185-177-2-115.sslip.io:443:10.10.10.6'
correct_status=$(curl -ksS --resolve "$resolve" -o /tmp/tvoice-chat-correct-login.json -w '%{http_code}' -H 'Content-Type: application/json' --data "$payload" 'https://chat.185-177-2-115.sslip.io/v1/auth/login')
wrong_status=$(curl -ksS --resolve "$resolve" -o /tmp/tvoice-chat-wrong-login.json -w '%{http_code}' -H 'Content-Type: application/json' --data '{"sipNumber":"73302","password":"definitely-wrong"}' 'https://chat.185-177-2-115.sslip.io/v1/auth/login')

echo "chat_login_http=$correct_status wrong_password_http=$wrong_status"
test "$correct_status" = 200
test "$wrong_status" = 401
