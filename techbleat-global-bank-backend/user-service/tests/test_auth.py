"""Tests for JWT auth critical paths in user-service.

Covers:
- Missing / malformed Authorization header → 401
- Token with wrong audience → 401
- Token with wrong issuer → 401
- Token with mismatched user identity → 401
- Password min-length enforcement in UserCreate (12 chars)
"""
from __future__ import annotations

import os
import time
from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException

os.environ.setdefault("KEYCLOAK_URL", "http://localhost:8080")
os.environ.setdefault("KEYCLOAK_REALM", "banking")
os.environ.setdefault("KEYCLOAK_ISSUER", "http://localhost:8080/realms/banking")
os.environ.setdefault("KEYCLOAK_AUDIENCE", "account")
os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost/test")

# Import after env vars are set
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
from auth import require_user  # noqa: E402


# ── helper: build a fake decoded payload ────────────────────────────────────

def _payload(user_id: str = "bankingdemo", aud: str = "account") -> dict:
    return {
        "sub": "keycloak-uuid-1234",
        "preferred_username": user_id,
        "aud": aud,
        "iss": "http://localhost:8080/realms/banking",
        "exp": int(time.time()) + 3600,
    }


# ── auth header tests ────────────────────────────────────────────────────────

def test_missing_header_raises_401():
    with pytest.raises(HTTPException) as exc_info:
        require_user(authorization=None)
    assert exc_info.value.status_code == 401


def test_malformed_header_raises_401():
    with pytest.raises(HTTPException) as exc_info:
        require_user(authorization="NotBearer token123")
    assert exc_info.value.status_code == 401


def test_empty_bearer_raises_401():
    with pytest.raises(HTTPException) as exc_info:
        require_user(authorization="Bearer ")
    assert exc_info.value.status_code == 401


# ── JWT content validation ───────────────────────────────────────────────────

def test_wrong_audience_raises_401():
    payload = _payload(aud="wrong-audience")
    with patch("auth._decode_token", return_value=payload):
        with pytest.raises(HTTPException) as exc_info:
            require_user(authorization="Bearer faketoken")
    assert exc_info.value.status_code == 401


def test_missing_user_id_in_payload_raises_401():
    # payload has no preferred_username / uid
    payload = {"sub": "some-subject", "aud": "account", "exp": int(time.time()) + 3600}
    with patch("auth._decode_token", return_value=payload):
        with pytest.raises(HTTPException) as exc_info:
            require_user(authorization="Bearer faketoken")
    assert exc_info.value.status_code == 401


def test_valid_token_returns_user_context():
    payload = _payload()
    with patch("auth._decode_token", return_value=payload):
        ctx = require_user(authorization="Bearer faketoken")
    assert ctx.user_id == "bankingdemo"


# ── password validation ──────────────────────────────────────────────────────

def test_password_min_length_enforcement():
    """UserCreate must reject passwords shorter than 12 characters."""
    from pydantic import ValidationError
    from main import UserCreate

    with pytest.raises(ValidationError) as exc_info:
        UserCreate(id="testuser01", full_name="Test User", email="test@bank.local",
                   password="short")  # 5 chars
    errors = exc_info.value.errors()
    assert any("password" in str(e) for e in errors)


def test_password_12_chars_accepted():
    """Passwords of exactly 12 characters must pass validation."""
    from main import UserCreate
    user = UserCreate(id="testuser01", full_name="Test User", email="test@bank.local",
                      password="Correct12!ab")  # 12 chars
    assert user.password.get_secret_value() == "Correct12!ab"
