#!/usr/bin/env python3
"""
Generate an encrypted Basic Auth secret for --basic_auth_password_enc /
SELKIES_BASIC_AUTH_PASSWORD_ENC. Prompts for a password (not echoed, not
stored anywhere) and prints the base64 blob to store instead.

Usage:
    python3 tools/gen_basic_auth_secret.py
"""
import getpass
import sys

sys.path.insert(0, "src")
from selkies_gstreamer.auth_secret import generate

password = getpass.getpass("Password to encrypt: ")
confirm = getpass.getpass("Confirm: ")
if password != confirm:
    sys.exit("Passwords did not match.")
if not password:
    sys.exit("Password must not be empty.")

print(generate(password))
