<?php
/**
 * Diagnostics page to check server configuration
 * Access via: https://vibecheck.wanderingstan.com/diagnostics
 * DELETE THIS FILE after debugging for security!
 */

header('Content-Type: text/plain');

echo "=== Vibe Check Diagnostics ===\n\n";

// 1. Check if config.json is readable
echo "1. Config file check:\n";
$config_path = __DIR__ . '/config.json';
if (file_exists($config_path)) {
    echo "   ✓ config.json exists\n";
    if (is_readable($config_path)) {
        echo "   ✓ config.json is readable\n";
        $config = json_decode(file_get_contents($config_path), true);
        if ($config) {
            echo "   ✓ config.json is valid JSON\n";
        } else {
            echo "   ✗ config.json is NOT valid JSON\n";
        }
    } else {
        echo "   ✗ config.json is NOT readable (permission issue!)\n";
        echo "   File permissions: " . substr(sprintf('%o', fileperms($config_path)), -4) . "\n";
        echo "   File owner: " . posix_getpwuid(fileowner($config_path))['name'] . "\n";
        echo "   Current user: " . posix_getpwuid(posix_geteuid())['name'] . "\n";
    }
} else {
    echo "   ✗ config.json does NOT exist\n";
}

echo "\n";

// 2. Check database connection
echo "2. Database connection check:\n";
if (isset($config)) {
    $mysqli = @new mysqli(
        $config['mysql']['host'],
        $config['mysql']['user'],
        $config['mysql']['password'],
        $config['mysql']['database']
    );

    if ($mysqli->connect_error) {
        echo "   ✗ Database connection FAILED: " . $mysqli->connect_error . "\n";
    } else {
        echo "   ✓ Database connected successfully\n";

        // Check if tables exist
        $result = $mysqli->query("SHOW TABLES LIKE 'conversation_events'");
        if ($result && $result->num_rows > 0) {
            echo "   ✓ conversation_events table exists\n";
        } else {
            echo "   ✗ conversation_events table does NOT exist\n";
        }

        $result = $mysqli->query("SHOW TABLES LIKE 'api_keys'");
        if ($result && $result->num_rows > 0) {
            echo "   ✓ api_keys table exists\n";
        } else {
            echo "   ✗ api_keys table does NOT exist\n";
        }

        $mysqli->close();
    }
} else {
    echo "   ⊘ Skipped (config not loaded)\n";
}

echo "\n";

// 3. Check file permissions
echo "3. File permissions:\n";
$files_to_check = ['api.php', 'config.json', 'diagnostics.php'];
foreach ($files_to_check as $file) {
    $path = __DIR__ . '/' . $file;
    if (file_exists($path)) {
        $perms = substr(sprintf('%o', fileperms($path)), -4);
        $owner = posix_getpwuid(fileowner($path))['name'];
        echo "   $file: $perms (owner: $owner)\n";
    }
}

echo "\n";

// 4. PHP error log location
echo "4. PHP error log:\n";
$error_log = ini_get('error_log');
if ($error_log) {
    echo "   Location: $error_log\n";
} else {
    echo "   Using system default location\n";
}

echo "\n";

// 5. Recent PHP errors (last 20 lines)
echo "5. Recent PHP errors:\n";
if ($error_log && file_exists($error_log) && is_readable($error_log)) {
    $lines = file($error_log);
    $recent = array_slice($lines, -20);
    foreach ($recent as $line) {
        echo "   " . trim($line) . "\n";
    }
} else {
    echo "   (Unable to read error log)\n";
}

echo "\n=== End Diagnostics ===\n";
echo "\n⚠️  DELETE THIS FILE after debugging!\n";
?>
