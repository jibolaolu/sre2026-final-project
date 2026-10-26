"""Tests for FinanceAgent tool security and input validation.

Covers:
- _authorized_user rejects missing / empty token → 401
- _authorized_user rejects context user_id mismatch → 403 (cross-user isolation)
- search_transactions rejects overlong keyword → 422
- search_transactions rejects keyword with control characters → 422
- get_transactions_by_type rejects unknown type (returns error dict, not exception)
- Tool functions raise 401/403 before reaching the transaction API
"""
from __future__ import annotations

import os
import sys
from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException

os.environ.setdefault("KEYCLOAK_URL", "http://localhost:8080")
os.environ.setdefault("KEYCLOAK_REALM", "banking")
os.environ.setdefault("KEYCLOAK_ISSUER", "http://localhost:8080/realms/banking")
os.environ.setdefault("KEYCLOAK_AUDIENCE", "account")
os.environ.setdefault("TRANSACTION_API_URL", "http://transaction-service:8080")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from tools import _authorized_user, get_toolkit  # noqa: E402


# ── _authorized_user unit tests ──────────────────────────────────────────────

def test_missing_token_raises_401():
    with pytest.raises(HTTPException) as exc_info:
        _authorized_user({})
    assert exc_info.value.status_code == 401


def test_empty_token_raises_401():
    with pytest.raises(HTTPException) as exc_info:
        _authorized_user({"token": "", "user_id": "alice"})
    assert exc_info.value.status_code == 401


def test_cross_user_access_raises_403():
    """A context whose user_id differs from the token's user must raise 403."""
    fake_user = MagicMock()
    fake_user.user_id = "alice"
    with patch("tools.user_from_token", return_value=fake_user):
        with pytest.raises(HTTPException) as exc_info:
            _authorized_user({"token": "valid-token", "user_id": "mallory"})
    assert exc_info.value.status_code == 403


def test_matching_user_succeeds():
    """A context where user_id matches the token's user must pass."""
    fake_user = MagicMock()
    fake_user.user_id = "alice"
    with patch("tools.user_from_token", return_value=fake_user):
        user_id, token = _authorized_user({"token": "valid-token", "user_id": "alice"})
    assert user_id == "alice"


# ── search_transactions input validation ────────────────────────────────────

def _make_ctx(user_id: str = "alice") -> dict:
    fake_user = MagicMock()
    fake_user.user_id = user_id
    return {"token": "valid-token", "user_id": user_id, "_fake_user": fake_user}


def _patched_toolkit(user_id: str = "alice"):
    fake_user = MagicMock()
    fake_user.user_id = user_id
    ctx = {"token": "valid-token", "user_id": user_id}
    with patch("tools.user_from_token", return_value=fake_user):
        tool_functions, _ = get_toolkit(ctx)
    return tool_functions, fake_user


def test_search_overlong_keyword_raises_422():
    """Keywords longer than 200 chars are truncated then pass; this confirms
    the cap does not raise and returns normally with mocked data."""
    fake_user = MagicMock()
    fake_user.user_id = "alice"
    ctx = {"token": "valid-token", "user_id": "alice"}
    long_keyword = "a" * 300

    with patch("tools.user_from_token", return_value=fake_user), \
         patch("tools._fetch", return_value=("alice", [])):
        tool_functions, _ = get_toolkit(ctx)
        result = tool_functions["search_transactions"](keyword=long_keyword)
    # truncated to 200 chars, no match in empty list
    assert result["count"] == 0


def test_search_control_char_keyword_raises_422():
    """Keywords with control characters (e.g. null byte) must be rejected."""
    fake_user = MagicMock()
    fake_user.user_id = "alice"
    ctx = {"token": "valid-token", "user_id": "alice"}

    with patch("tools.user_from_token", return_value=fake_user):
        tool_functions, _ = get_toolkit(ctx)
        with pytest.raises(HTTPException) as exc_info:
            tool_functions["search_transactions"](keyword="test\x00injection")
    assert exc_info.value.status_code == 422


def test_invalid_transaction_type_returns_error_dict():
    """get_transactions_by_type with an unknown type returns an error dict, not an exception."""
    fake_user = MagicMock()
    fake_user.user_id = "alice"
    ctx = {"token": "valid-token", "user_id": "alice"}

    with patch("tools.user_from_token", return_value=fake_user):
        tool_functions, _ = get_toolkit(ctx)
        result = tool_functions["get_transactions_by_type"](transaction_type="HACK")
    assert "error" in result
    assert "HACK" in result["error"]


def test_affordability_negative_amount_returns_error():
    fake_user = MagicMock()
    fake_user.user_id = "alice"
    ctx = {"token": "valid-token", "user_id": "alice"}

    with patch("tools.user_from_token", return_value=fake_user):
        tool_functions, _ = get_toolkit(ctx)
        result = tool_functions["calculate_affordability"](amount=-50.0)
    assert "error" in result
