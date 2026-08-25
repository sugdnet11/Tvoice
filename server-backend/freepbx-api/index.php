<?php

declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

function respond(int $status, array $body): never
{
    http_response_code($status);
    echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

$remoteAddress = $_SERVER['REMOTE_ADDR'] ?? '';
if (!in_array($remoteAddress, ['10.10.10.6', '127.0.0.1', '::1'], true)) {
    respond(403, ['error' => 'forbidden']);
}

$keyPath = '/etc/tvoice-auth.key';
$expectedKey = is_readable($keyPath) ? trim((string) file_get_contents($keyPath)) : '';
$providedKey = $_SERVER['HTTP_X_TVOICE_KEY'] ?? '';

if (
    $expectedKey === ''
    || !hash_equals($expectedKey, $providedKey)
) {
    respond(403, ['error' => 'forbidden']);
}

try {
    require_once '/etc/freepbx.conf';
    $database = FreePBX::Database();
    $action = $_GET['action'] ?? '';

    if ($action === 'auth') {
        if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
            respond(405, ['error' => 'method_not_allowed']);
        }
        $body = json_decode((string) file_get_contents('php://input'), true);
        $sipNumber = is_array($body) ? trim((string) ($body['sipNumber'] ?? '')) : '';
        $password = is_array($body) ? (string) ($body['password'] ?? '') : '';
        if (!preg_match('/^[0-9*#+]{2,32}$/', $sipNumber) || $password === '' || strlen($password) > 256) {
            respond(400, ['error' => 'invalid_request']);
        }

        $statement = $database->prepare(
            "SELECT u.extension AS sip_number,
                    COALESCE(NULLIF(u.name, ''), u.extension) AS display_name,
                    s.data AS sip_secret
             FROM users u
             JOIN sip s ON s.id = u.extension AND s.keyword = 'secret'
             WHERE u.extension = ?
             LIMIT 1"
        );
        $statement->execute([$sipNumber]);
        $user = $statement->fetch(PDO::FETCH_ASSOC);
        if (!$user || !hash_equals((string) $user['sip_secret'], $password)) {
            respond(401, ['error' => 'invalid_credentials']);
        }

        respond(200, [
            'user' => [
                'sipNumber' => (string) $user['sip_number'],
                'displayName' => (string) $user['display_name'],
            ],
        ]);
    }

    if ($action === 'users') {
        if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
            respond(405, ['error' => 'method_not_allowed']);
        }
        $statement = $database->query(
            "SELECT u.extension AS sip_number,
                    COALESCE(NULLIF(u.name, ''), u.extension) AS display_name
             FROM users u
             JOIN sip s ON s.id = u.extension AND s.keyword = 'secret' AND s.data <> ''
             WHERE u.extension REGEXP '^[0-9*#+]{2,32}$'
             ORDER BY u.extension"
        );
        $users = [];
        while ($row = $statement->fetch(PDO::FETCH_ASSOC)) {
            $users[] = [
                'sipNumber' => (string) $row['sip_number'],
                'displayName' => (string) $row['display_name'],
            ];
        }
        respond(200, ['users' => $users]);
    }

    respond(404, ['error' => 'not_found']);
} catch (Throwable $error) {
    error_log('Tvoice FreePBX auth API failure: ' . $error->getMessage());
    respond(500, ['error' => 'internal_error']);
}
