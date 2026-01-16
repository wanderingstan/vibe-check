# Secret Detection

This feature automatically detects and redacts secrets (API keys, passwords, tokens, etc.) from conversation messages to prevent accidental exposure of sensitive data.

## Features

- **Real-time Detection**: New messages are scanned before being stored in the database
- **Retroactive Scanning**: Scan existing database records for secrets
- **Comprehensive Coverage**: Detects 20+ types of secrets including:
  - AWS Access Keys
  - GitHub Tokens
  - API Keys (Stripe, OpenAI, SendGrid, etc.)
  - Private Keys (RSA, SSH)
  - Database Connection Strings
  - JWT Tokens
  - And more...

## How It Works

### Real-time Protection

The `monitor.py` script automatically scans all new messages for secrets before storing them:

1. When a new message is processed, it's scanned using `detect-secrets`
2. If secrets are detected, the entire message is replaced with `<SECRET REDACTED>`
3. The redacted message is stored in both the local SQLite and remote MySQL databases
4. A warning is logged: `⚠️  Secret detected and redacted in message`

### Retroactive Scanning

Use the `scripts/scan_and_redact_secrets.py` script to scan your existing database:

```bash
# Activate virtual environment
source venv/bin/activate

# Dry run (shows what would be changed without making changes)
python scripts/scan_and_redact_secrets.py --dry-run

# Actually redact secrets (makes changes to the database)
python scripts/scan_and_redact_secrets.py

# Scan only the first 100 records
python scripts/scan_and_redact_secrets.py --dry-run --limit 100

# Use a different config file
python scripts/scan_and_redact_secrets.py --config /path/to/config.json
```

**IMPORTANT**: Always run with `--dry-run` first to see what would be changed!

## Configuration

### Secret Detection Plugins

The detection uses these plugins from `detect-secrets`:

- AWSKeyDetector
- GitHubTokenDetector
- OpenAIDetector
- PrivateKeyDetector
- BasicAuthDetector
- And 17 more...

High-entropy string detectors (Base64/Hex) are disabled by default to reduce false positives in conversational text.

### Customizing Detection

Edit `secret_detector.py` and modify the `DEFAULT_PLUGINS` list to add or remove detectors:

```python
DEFAULT_PLUGINS = [
    {'name': 'AWSKeyDetector'},
    {'name': 'GitHubTokenDetector'},
    # Add more plugins here...
]
```

## Testing

Test the detection on sample strings:

```bash
source venv/bin/activate
python secret_detector.py
```

This runs built-in tests on sample text containing secrets.

## Files

- `secret_detector.py` - Core secret detection library
- `scripts/scan_and_redact_secrets.py` - Retroactive database scanner
- `monitor.py` - Modified to include real-time secret detection

## Security Notes

1. **Redaction is permanent**: Once a message is redacted, the original text cannot be recovered
2. **False positives**: Some legitimate text may be flagged as secrets (though this is minimized)
3. **False negatives**: Not all secrets can be detected (custom API keys, unusual formats, etc.)
4. **Database backups**: Secrets may still exist in database backups made before redaction

## Best Practices

1. Run `scripts/scan_and_redact_secrets.py --dry-run` regularly to check for secrets
2. Review the dry-run output to verify detections are accurate
3. Keep your `detect-secrets` library updated: `pip install --upgrade detect-secrets`
4. Consider rotating any secrets that were accidentally committed
5. Backup your database before running live redaction

## Troubleshooting

### "pymysql is required"

Install the MySQL connector:
```bash
source venv/bin/activate
pip install pymysql
```

### "Config file not found"

Make sure you're running from the vibe-check directory and the config file exists:
```bash
ls -l server-php/config.json
```

### Too many false positives

Edit `secret_detector.py` and comment out overly sensitive plugins like `KeywordDetector`.

### Secret not detected

The secret may use an unusual format. Consider:
1. Adding a custom regex pattern to `secret_detector.py`
2. Enabling high-entropy detectors (but expect more false positives)
3. Manually redacting the specific record

## Support

For issues or questions, see the main README or open an issue on GitHub.
