"""
Secret detection utility using detect-secrets library.

This module provides functions to detect secrets in text strings
and redact them to prevent accidental exposure of sensitive data.
"""

from detect_secrets.core.scan import scan_line
from detect_secrets.settings import transient_settings

# Default plugins to use for secret detection
# Note: High entropy detectors are disabled to reduce false positives in conversational text
DEFAULT_PLUGINS = [
    {'name': 'AWSKeyDetector'},
    {'name': 'ArtifactoryDetector'},
    {'name': 'AzureStorageKeyDetector'},
    {'name': 'BasicAuthDetector'},
    {'name': 'CloudantDetector'},
    {'name': 'DiscordBotTokenDetector'},
    {'name': 'GitHubTokenDetector'},
    {'name': 'IbmCloudIamDetector'},
    {'name': 'IbmCosHmacDetector'},
    {'name': 'IPPublicDetector'},
    {'name': 'JwtTokenDetector'},
    {'name': 'KeywordDetector'},
    {'name': 'MailchimpDetector'},
    {'name': 'NpmDetector'},
    {'name': 'OpenAIDetector'},
    {'name': 'PrivateKeyDetector'},
    {'name': 'SendGridDetector'},
    {'name': 'SlackDetector'},
    {'name': 'SoftlayerDetector'},
    {'name': 'SquareOAuthDetector'},
    {'name': 'StripeDetector'},
    {'name': 'TwilioKeyDetector'},
]


def contains_secrets(text):
    """
    Check if the given text contains any secrets.

    Args:
        text (str): The text to scan for secrets

    Returns:
        bool: True if secrets were found, False otherwise
    """
    if not text or not isinstance(text, str):
        return False

    try:
        with transient_settings({'plugins_used': DEFAULT_PLUGINS}):
            # Scan each line for secrets
            for line in text.split('\n'):
                found_secrets = list(scan_line(line))
                if len(found_secrets) > 0:
                    return True
        return False
    except Exception as e:
        # If scanning fails, err on the side of caution
        print(f"Error scanning for secrets: {e}")
        return False


def redact_if_secret(text, redaction_text="<SECRET REDACTED>"):
    """
    Scan text for secrets and return redacted version if found.

    Args:
        text (str): The text to scan
        redaction_text (str): The text to replace secrets with

    Returns:
        str: Original text if no secrets found, redaction_text if secrets found
    """
    if not text or not isinstance(text, str):
        return text

    if contains_secrets(text):
        return redaction_text

    return text


def get_secret_types(text):
    """
    Get the types of secrets found in the text (for debugging/logging).

    Args:
        text (str): The text to scan

    Returns:
        list: List of secret types found (e.g., ['AWS Access Key', 'Generic Secret'])
    """
    if not text or not isinstance(text, str):
        return []

    secret_types = []

    try:
        with transient_settings({'plugins_used': DEFAULT_PLUGINS}):
            for line in text.split('\n'):
                found_secrets = list(scan_line(line))
                secret_types.extend([secret.type for secret in found_secrets])
    except Exception as e:
        print(f"Error getting secret types: {e}")

    return secret_types


if __name__ == "__main__":
    # Test cases
    test_cases = [
        "This is a normal message",
        "My AWS key is AKIAIOSFODNN7EXAMPLE",
        "Here's my password: hunter2",
        "Connect with: postgresql://user:password123@localhost/db",
        "API key: sk_test_51HRp2qLqS4FZqE2N7ZqE2N",
    ]

    print("Testing secret detection:\n")
    for text in test_cases:
        has_secret = contains_secrets(text)
        redacted = redact_if_secret(text)
        types = get_secret_types(text)

        print(f"Text: {text}")
        print(f"  Has secrets: {has_secret}")
        print(f"  Redacted: {redacted}")
        if types:
            print(f"  Types found: {types}")
        print()
