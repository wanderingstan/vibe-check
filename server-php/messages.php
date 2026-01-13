<?php
/**
 * Vibe Check Messages Viewer
 *
 * Displays recent conversation messages
 */

error_reporting(E_ALL);
ini_set('display_errors', 1);
ini_set('log_errors', 1);

// Load configuration
$config = json_decode(file_get_contents(__DIR__ . '/config.json'), true);

// Database connection
$mysqli = new mysqli(
    $config['mysql']['host'],
    $config['mysql']['user'],
    $config['mysql']['password'],
    $config['mysql']['database']
);

if ($mysqli->connect_error) {
    die("Database connection failed: " . $mysqli->connect_error);
}

$mysqli->set_charset('utf8mb4');

// Get username filter from query parameter
$filter_username = isset($_GET['user']) ? trim($_GET['user']) : null;

// Build WHERE clause for username filtering
$where_user_filter = "";
if ($filter_username) {
    $escaped_username = $mysqli->real_escape_string($filter_username);
    $where_user_filter = " AND user_name = '$escaped_username'";
}

// Get all unique usernames for the user list
$users_query = "
    SELECT DISTINCT user_name
    FROM conversation_events
    WHERE user_name IS NOT NULL AND user_name != ''
    ORDER BY user_name ASC
";
$result = $mysqli->query($users_query);
$all_users = [];
while ($row = $result->fetch_assoc()) {
    $all_users[] = $row['user_name'];
}

// Query for messages where event_message is not null
$messages_query = "
    SELECT
        id,
        file_name,
        line_number,
        event_type,
        event_message,
        user_name,
        inserted_at
    FROM conversation_events
    WHERE event_message IS NOT NULL
        AND event_message != ''
        $where_user_filter
    ORDER BY inserted_at DESC
    LIMIT 150
";

$result = $mysqli->query($messages_query);
$messages = [];
while ($row = $result->fetch_assoc()) {
    $messages[] = [
        'id' => $row['id'],
        'event_type' => $row['event_type'],
        'content' => $row['event_message'],
        'file_name' => $row['file_name'],
        'line_number' => $row['line_number'],
        'user_name' => $row['user_name'],
        'inserted_at' => $row['inserted_at']
    ];
}

$mysqli->close();

?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Vibe Check Messages</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: #0f1419;
            color: #e6edf3;
            padding: 2rem;
            line-height: 1.6;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
        }

        h1 {
            font-size: 2.5rem;
            margin-bottom: 0.5rem;
            background: linear-gradient(135deg, #6366f1 0%, #a855f7 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .subtitle {
            color: #8b949e;
            margin-bottom: 3rem;
            font-size: 1.1rem;
        }

        .user-filter {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 12px;
            padding: 1.5rem;
            margin-bottom: 2rem;
        }

        .user-filter-title {
            font-size: 0.875rem;
            color: #8b949e;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 1rem;
        }

        .user-list {
            display: flex;
            flex-wrap: wrap;
            gap: 0.5rem;
        }

        .user-tag {
            display: inline-block;
            padding: 0.5rem 1rem;
            background: #21262d;
            border: 1px solid #30363d;
            border-radius: 6px;
            color: #8b949e;
            text-decoration: none;
            font-size: 0.875rem;
            transition: all 0.2s;
        }

        .user-tag:hover {
            background: #30363d;
            color: #e6edf3;
            border-color: #6366f1;
            transform: translateY(-1px);
        }

        .user-tag.active {
            background: linear-gradient(135deg, #6366f1 0%, #a855f7 100%);
            border-color: #6366f1;
            color: #fff;
            font-weight: 600;
        }

        .user-tag.all {
            background: #30363d;
            color: #e6edf3;
        }

        .user-tag.all.active {
            background: linear-gradient(135deg, #10b981 0%, #06b6d4 100%);
            border-color: #10b981;
        }

        .messages-container {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 12px;
            padding: 2rem;
            margin-bottom: 2rem;
        }

        .messages-title {
            font-size: 1.25rem;
            margin-bottom: 1.5rem;
            color: #e6edf3;
        }

        .message {
            background: #21262d;
            border: 1px solid #30363d;
            border-radius: 8px;
            padding: 1.5rem;
            margin-bottom: 1rem;
            transition: border-color 0.2s;
        }

        .message:hover {
            border-color: #6366f1;
        }

        .message.user {
            border-left: 4px solid #10b981;
        }

        .message.assistant {
            border-left: 4px solid #6366f1;
        }

        .message-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 0.75rem;
            flex-wrap: wrap;
            gap: 0.5rem;
        }

        .message-type {
            display: inline-block;
            padding: 0.25rem 0.75rem;
            border-radius: 4px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }

        .message-type.user {
            background: rgba(16, 185, 129, 0.2);
            color: #10b981;
        }

        .message-type.assistant {
            background: rgba(99, 102, 241, 0.2);
            color: #6366f1;
        }

        .message-meta {
            color: #8b949e;
            font-size: 0.875rem;
            display: flex;
            gap: 1rem;
            flex-wrap: wrap;
        }

        .message-content {
            color: #e6edf3;
            white-space: pre-wrap;
            word-break: break-word;
            line-height: 1.6;
            max-height: 400px;
            overflow-y: auto;
        }

        .message-footer {
            margin-top: 0.75rem;
            padding-top: 0.75rem;
            border-top: 1px solid #30363d;
            color: #6e7681;
            font-size: 0.75rem;
            display: flex;
            gap: 1rem;
            flex-wrap: wrap;
        }

        .footer {
            text-align: center;
            color: #6e7681;
            margin-top: 3rem;
            padding-top: 2rem;
            border-top: 1px solid #30363d;
        }

        .no-messages {
            text-align: center;
            color: #8b949e;
            padding: 3rem;
            font-size: 1.1rem;
        }

        .nav-links {
            margin-bottom: 1rem;
        }

        .nav-link {
            color: #6366f1;
            text-decoration: none;
            margin-right: 1rem;
            font-size: 0.9rem;
        }

        .nav-link:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="nav-links">
            <a href="stats.php" class="nav-link">← Back to Stats</a>
        </div>

        <h1>Vibe Check Messages</h1>
        <p class="subtitle">
            <?php
            if ($filter_username) {
                echo "Messages for <strong>@" . htmlspecialchars($filter_username) . "</strong>";
            } else {
                echo "Recent conversation messages";
            }
            ?>
        </p>

        <div class="user-filter">
            <div class="user-filter-title">Filter by User</div>
            <div class="user-list">
                <a href="messages.php" class="user-tag all <?php echo !$filter_username ? 'active' : ''; ?>">
                    All Users
                </a>
                <?php foreach ($all_users as $user): ?>
                    <a href="messages.php?user=<?php echo urlencode($user); ?>"
                       class="user-tag <?php echo ($filter_username === $user) ? 'active' : ''; ?>">
                        @<?php echo htmlspecialchars($user); ?>
                    </a>
                <?php endforeach; ?>
            </div>
        </div>

        <div class="messages-container">
            <h2 class="messages-title">Recent Messages (150 most recent)</h2>

            <?php if (empty($messages)): ?>
                <div class="no-messages">No messages found</div>
            <?php else: ?>
                <?php foreach ($messages as $msg): ?>
                    <div class="message <?php echo htmlspecialchars($msg['event_type']); ?>">
                        <div class="message-header">
                            <span class="message-type <?php echo htmlspecialchars($msg['event_type']); ?>">
                                <?php echo htmlspecialchars($msg['event_type']); ?>
                            </span>
                            <div class="message-meta">
                                <span>@<?php echo htmlspecialchars($msg['user_name']); ?></span>
                                <span><?php echo date('Y-m-d H:i:s', strtotime($msg['inserted_at'])); ?></span>
                            </div>
                        </div>

                        <div class="message-content"><?php echo htmlspecialchars($msg['content']); ?></div>

                        <div class="message-footer">
                            <span>File: <?php echo htmlspecialchars($msg['file_name']); ?></span>
                            <span>Line: <?php echo htmlspecialchars($msg['line_number']); ?></span>
                            <span>ID: <?php echo htmlspecialchars($msg['id']); ?></span>
                        </div>
                    </div>
                <?php endforeach; ?>
            <?php endif; ?>
        </div>

        <div class="footer">
            Showing <?php echo count($messages); ?> messages | Last updated: <?php echo date('Y-m-d H:i:s'); ?>
        </div>
    </div>
</body>
</html>
