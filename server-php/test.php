<?php
// Simple test file to check if PHP is working
header('Content-Type: application/json');

echo json_encode([
    'status' => 'ok',
    'message' => 'PHP is working!',
    'server' => $_SERVER['SERVER_NAME'],
    'php_version' => PHP_VERSION,
    'request_uri' => $_SERVER['REQUEST_URI'],
    'script_name' => $_SERVER['SCRIPT_NAME']
]);
?>
