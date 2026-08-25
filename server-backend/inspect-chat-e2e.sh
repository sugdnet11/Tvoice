#!/bin/sh
set -u

php -r '
$files = [
  "login73302" => "/tmp/tvoice-login-73302.json",
  "login77770" => "/tmp/tvoice-login-77770.json",
  "contacts" => "/tmp/tvoice-contacts.json",
  "conversation" => "/tmp/tvoice-conversation.json",
  "sent" => "/tmp/tvoice-message-sent.json",
  "received" => "/tmp/tvoice-message-received.json",
  "read" => "/tmp/tvoice-message-read.json",
  "senderView" => "/tmp/tvoice-sender-messages.json",
];
foreach ($files as $label => $path) {
  if (!is_file($path)) { echo "$label=missing\n"; continue; }
  $v = json_decode(file_get_contents($path), true);
  if (!is_array($v)) { echo "$label=invalid_json\n"; continue; }
  if ($label === "login73302" || $label === "login77770") {
    echo $label . "=" . (isset($v["accessToken"]) ? "token_present" : ($v["error"] ?? "unexpected")) . "\n";
  } elseif ($label === "contacts") {
    echo "contacts=" . count($v["contacts"] ?? []) . "\n";
  } elseif ($label === "conversation") {
    echo "conversation=" . (isset($v["conversation"]["id"]) ? "present" : ($v["error"] ?? "unexpected")) . "\n";
  } elseif ($label === "sent") {
    echo "sent=" . ($v["message"]["status"] ?? $v["error"] ?? "unexpected") . "\n";
  } elseif ($label === "read") {
    echo "read=" . (isset($v["readThrough"]) ? "present" : ($v["error"] ?? "unexpected")) . "\n";
  } else {
    $found = "missing";
    foreach (($v["messages"] ?? []) as $message) {
      if (str_starts_with($message["body"] ?? "", "[Tvoice system test]")) {
        $found = $message["status"] ?? "present";
      }
    }
    echo "$label=$found\n";
  }
}
'
