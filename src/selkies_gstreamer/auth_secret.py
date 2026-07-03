# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""
Password-derived AES-256-GCM encrypted secret for HTTP Basic Auth.

Instead of storing the Basic Auth password in cleartext, only an encrypted
blob (iv || authTag || ciphertext) is kept, holding whatever plaintext the
blob was originally generated with (content doesn't matter). Verification
works by deriving an AES-256 key from the candidate password and attempting
to decrypt the blob: GCM's authentication tag only checks out if the
candidate password was correct, regardless of what the plaintext is.

Key derivation and blob layout match a pre-existing external tool (MD5 x5,
then SHA-256 x5, no salt) so blobs generated there can be used here as-is.
"""
import base64
import hashlib
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

_MAGIC = b"selkies-auth-ok"
_IV_LEN = 12
_TAG_LEN = 16


def _derive_key(password: str) -> bytes:
    h = password
    for _ in range(5):
        h = hashlib.md5(h.encode("utf-8")).hexdigest()
    buf = h.encode("utf-8")
    for _ in range(5):
        buf = hashlib.sha256(buf).digest()
    return buf  # 32 bytes -> AES-256 key


def generate(password: str) -> str:
    """Return a base64 blob that verify() can later check a password against."""
    iv = os.urandom(_IV_LEN)
    key = _derive_key(password)
    ciphertext_and_tag = AESGCM(key).encrypt(iv, _MAGIC, None)
    ciphertext, tag = ciphertext_and_tag[:-_TAG_LEN], ciphertext_and_tag[-_TAG_LEN:]
    return base64.b64encode(iv + tag + ciphertext).decode("ascii")


def verify(password: str, blob_b64: str) -> bool:
    """Return True if password successfully decrypts blob_b64 (as produced by
    generate(), or by the external tool that produces
    iv(12) || authTag(16) || ciphertext). The decrypted content is not
    checked against anything; a valid GCM tag is proof enough that password
    was the one the blob was encrypted with."""
    try:
        blob = base64.b64decode(blob_b64)
        iv = blob[:_IV_LEN]
        tag = blob[_IV_LEN:_IV_LEN + _TAG_LEN]
        ciphertext = blob[_IV_LEN + _TAG_LEN:]
        if len(iv) != _IV_LEN or len(tag) != _TAG_LEN or not ciphertext:
            return False
        key = _derive_key(password)
        AESGCM(key).decrypt(iv, ciphertext + tag, None)
        return True
    except (InvalidTag, ValueError, IndexError):
        return False
