<?php
/**
 * Vibe Check API - PHP Edition
 *
 * Simple PHP API for receiving conversation events from monitors.
 * Uses API key authentication.
 */

// Enable error logging for debugging
error_reporting(E_ALL);
ini_set('display_errors', 0);
ini_set('log_errors', 1);

header('Content-Type: application/json');

// Load configuration
$config = json_decode(file_get_contents(__DIR__ . '/config.json'), true);

// Database connection
function get_db_connection($config) {
    $mysqli = new mysqli(
        $config['mysql']['host'],
        $config['mysql']['user'],
        $config['mysql']['password'],
        $config['mysql']['database']
    );

    if ($mysqli->connect_error) {
        error_log("Database connection failed: " . $mysqli->connect_error);
        http_response_code(500);
        echo json_encode(['error' => 'Database connection failed']);
        exit;
    }

    $mysqli->set_charset('utf8mb4');
    return $mysqli;
}

// Validate API key
function validate_api_key($mysqli, $api_key) {
    if (empty($api_key)) {
        return null;
    }

    $stmt = $mysqli->prepare("SELECT user_name FROM api_keys WHERE api_key = ? AND is_active = TRUE");
    $stmt->bind_param("s", $api_key);
    $stmt->execute();
    $result = $stmt->get_result();
    $user = $result->fetch_assoc();
    $stmt->close();

    if ($user) {
        // Update last_used_at
        $stmt = $mysqli->prepare("UPDATE api_keys SET last_used_at = NOW() WHERE api_key = ?");
        $stmt->bind_param("s", $api_key);
        $stmt->execute();
        $stmt->close();

        return $user['user_name'];
    }

    return null;
}

// Get API key from header
$api_key = null;
if (isset($_SERVER['HTTP_X_API_KEY'])) {
    $api_key = $_SERVER['HTTP_X_API_KEY'];
}

// Route handling
$request_method = $_SERVER['REQUEST_METHOD'];
$request_uri = $_SERVER['REQUEST_URI'];

// Remove query string
$path = parse_url($request_uri, PHP_URL_PATH);

// Remove trailing slash
$path = rtrim($path, '/');

// Get endpoint (everything after last slash, or 'health' if path is just /health)
$path_parts = explode('/', trim($path, '/'));
$endpoint = end($path_parts);

// Debug logging (remove after testing)
error_log("DEBUG: REQUEST_URI=" . $request_uri);
error_log("DEBUG: PATH=" . $path);
error_log("DEBUG: ENDPOINT=" . $endpoint);

// Health check endpoint (no auth required)
if ($endpoint === 'health' && $request_method === 'GET') {
    echo json_encode(['status' => 'ok']);
    exit;
}

// POST /create-token - Create new user and API token (no auth required)
if ($endpoint === 'create-token' && $request_method === 'POST') {
    $mysqli = get_db_connection($config);
    $input = json_decode(file_get_contents('php://input'), true);

    if (!$input || !isset($input['username'])) {
        http_response_code(400);
        echo json_encode(['error' => 'Missing required field: username']);
        exit;
    }

    $username = trim($input['username']);

    // Validate username
    if (empty($username)) {
        http_response_code(400);
        echo json_encode(['error' => 'Username cannot be empty']);
        exit;
    }

    if (strlen($username) > 100) {
        http_response_code(400);
        echo json_encode(['error' => 'Username too long (max 100 characters)']);
        exit;
    }

    // Check if username already exists
    $stmt = $mysqli->prepare("SELECT user_name FROM api_keys WHERE user_name = ?");
    $stmt->bind_param("s", $username);
    $stmt->execute();
    $result = $stmt->get_result();

    if ($result->num_rows > 0) {
        http_response_code(409);
        echo json_encode(['error' => 'Username already exists']);
        $stmt->close();
        $mysqli->close();
        exit;
    }
    $stmt->close();

    // Generate secure API key (32 bytes = 43 characters in base64url)
    $api_key = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');

    // Insert new user and API key
    $stmt = $mysqli->prepare("INSERT INTO api_keys (user_name, api_key) VALUES (?, ?)");
    $stmt->bind_param("ss", $username, $api_key);

    if ($stmt->execute()) {
        http_response_code(201);
        echo json_encode([
            'status' => 'ok',
            'username' => $username,
            'api_key' => $api_key,
            'message' => 'API token created successfully'
        ]);
    } else {
        error_log("Database error: " . $stmt->error);
        http_response_code(500);
        echo json_encode(['error' => 'Failed to create API token']);
    }

    $stmt->close();
    $mysqli->close();
    exit;
}

// All other endpoints require authentication
$mysqli = get_db_connection($config);
$user_name = validate_api_key($mysqli, $api_key);

if (!$user_name) {
    http_response_code(401);
    echo json_encode(['error' => 'Invalid or missing API key']);
    exit;
}

// POST /events - Create new event
if ($endpoint === 'events' && $request_method === 'POST') {
    $input = json_decode(file_get_contents('php://input'), true);

    if (!$input) {
        http_response_code(400);
        echo json_encode(['error' => 'Invalid JSON body']);
        exit;
    }

    // Validate required fields
    $required_fields = ['file_name', 'line_number', 'event_data'];
    $missing_fields = [];
    foreach ($required_fields as $field) {
        if (!isset($input[$field])) {
            $missing_fields[] = $field;
        }
    }

    if (!empty($missing_fields)) {
        http_response_code(400);
        echo json_encode(['error' => 'Missing required fields: ' . implode(', ', $missing_fields)]);
        exit;
    }

    // Insert event
    $stmt = $mysqli->prepare("
        INSERT INTO conversation_events (file_name, line_number, event_data, user_name)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE event_data = VALUES(event_data), user_name = VALUES(user_name)
    ");

    $event_data_json = json_encode($input['event_data']);
    $stmt->bind_param("siss", $input['file_name'], $input['line_number'], $event_data_json, $user_name);

    if ($stmt->execute()) {
        http_response_code(201);
        echo json_encode([
            'status' => 'ok',
            'file_name' => $input['file_name'],
            'line_number' => $input['line_number']
        ]);
    } else {
        error_log("Database error: " . $stmt->error);
        http_response_code(500);
        echo json_encode(['error' => 'Database error']);
    }

    $stmt->close();
    exit;
}

// GET /events - List recent events
if ($endpoint === 'events' && $request_method === 'GET') {
    $limit = isset($_GET['limit']) ? intval($_GET['limit']) : 10;
    $limit = max(1, min($limit, 100)); // Between 1 and 100

    $stmt = $mysqli->prepare("
        SELECT id, file_name, line_number, user_name, inserted_at
        FROM conversation_events
        ORDER BY inserted_at DESC
        LIMIT ?
    ");

    $stmt->bind_param("i", $limit);
    $stmt->execute();
    $result = $stmt->get_result();

    $events = [];
    while ($row = $result->fetch_assoc()) {
        $row['inserted_at'] = date('c', strtotime($row['inserted_at'])); // ISO 8601 format
        $events[] = $row;
    }

    echo json_encode(['events' => $events]);
    $stmt->close();
    exit;
}

// Unknown endpoint
http_response_code(404);
echo json_encode(['error' => 'Not found']);
$mysqli->close();
?>
