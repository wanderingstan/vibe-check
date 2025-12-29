#!/usr/bin/env python3
"""
Vibe Check API Server

Simple Flask API for receiving conversation events from monitors.
Uses API key authentication.
"""

import json
from pathlib import Path
from functools import wraps
from datetime import datetime

import pymysql
from flask import Flask, request, jsonify


app = Flask(__name__)

# Load configuration
config_path = Path(__file__).parent / 'config.json'
with open(config_path, 'r') as f:
    config = json.load(f)


def get_db_connection():
    """Get a database connection."""
    return pymysql.connect(
        host=config['mysql']['host'],
        port=config['mysql']['port'],
        user=config['mysql']['user'],
        password=config['mysql']['password'],
        database=config['mysql']['database'],
        charset='utf8mb4',
        cursorclass=pymysql.cursors.DictCursor
    )


def require_api_key(f):
    """Decorator to require valid API key."""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        api_key = request.headers.get('X-API-Key')

        if not api_key:
            return jsonify({'error': 'Missing API key'}), 401

        # Validate API key
        conn = get_db_connection()
        try:
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT user_name FROM api_keys WHERE api_key = %s AND is_active = TRUE",
                    (api_key,)
                )
                user = cursor.fetchone()

                if not user:
                    return jsonify({'error': 'Invalid API key'}), 401

                # Update last_used_at
                cursor.execute(
                    "UPDATE api_keys SET last_used_at = %s WHERE api_key = %s",
                    (datetime.now(), api_key)
                )
            conn.commit()

            # Store user info in request context
            request.user_name = user['user_name']

        finally:
            conn.close()

        return f(*args, **kwargs)

    return decorated_function


@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint."""
    return jsonify({'status': 'ok'})


@app.route('/events', methods=['POST'])
@require_api_key
def create_event():
    """
    Create a new conversation event.

    Expects JSON body:
    {
        "file_name": "path/to/file.jsonl",
        "line_number": 123,
        "event_data": {...}
    }
    """
    data = request.get_json()

    # Validate required fields
    if not data:
        return jsonify({'error': 'No JSON body provided'}), 400

    required_fields = ['file_name', 'line_number', 'event_data']
    missing_fields = [f for f in required_fields if f not in data]
    if missing_fields:
        return jsonify({'error': f'Missing required fields: {", ".join(missing_fields)}'}), 400

    # Insert event
    conn = get_db_connection()
    try:
        with conn.cursor() as cursor:
            sql = """
                INSERT INTO conversation_events (file_name, line_number, event_data)
                VALUES (%s, %s, %s)
                ON DUPLICATE KEY UPDATE event_data = VALUES(event_data)
            """
            cursor.execute(sql, (
                data['file_name'],
                data['line_number'],
                json.dumps(data['event_data'])
            ))
        conn.commit()

        return jsonify({
            'status': 'ok',
            'file_name': data['file_name'],
            'line_number': data['line_number']
        }), 201

    except Exception as e:
        app.logger.error(f"Error inserting event: {e}")
        return jsonify({'error': 'Database error'}), 500

    finally:
        conn.close()


@app.route('/events', methods=['GET'])
@require_api_key
def list_events():
    """List recent events (optional, for debugging)."""
    limit = request.args.get('limit', 10, type=int)

    conn = get_db_connection()
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT id, file_name, line_number, inserted_at
                FROM conversation_events
                ORDER BY inserted_at DESC
                LIMIT %s
                """,
                (limit,)
            )
            events = cursor.fetchall()

            # Convert datetime to string
            for event in events:
                event['inserted_at'] = event['inserted_at'].isoformat()

            return jsonify({'events': events})

    finally:
        conn.close()


def main():
    """Run the Flask development server."""
    app.run(
        host=config['server']['host'],
        port=config['server']['port'],
        debug=True
    )


if __name__ == '__main__':
    main()
