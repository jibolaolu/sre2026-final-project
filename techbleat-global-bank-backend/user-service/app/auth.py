"""JWT auth for user-service — Keycloak JWKS signature verification.

Environment variables:
- KEYCLOAK_URL     internal Keycloak URL, e.g. http://keycloak:8080
- KEYCLOAK_ISSUER  issuer claim in tokens, e.g. http://keycloak.techbleat-bank.local/realms/banking
- KEYCLOAK_REALM   e.g. banking
- KEYCLOAK_AUDIENCE e.g. account
"""
from __future__ import annotations

import os
import threading
import time
from functools import lru_cache
from typing import Any, Dict

import httpx
import jwt
from fastapi import Header, HTTPException, status


class UserContext(Dict[str, Any]):
    @property
    def user_id(self) -> str:
        return self.get("user_id", "")


def _get_env(name: str, default: str = "") -> str:
    value = os.getenv(name, default).strip()
    if name in ("KEYCLOAK_URL", "KEYCLOAK_ISSUER") and value.endswith("/"):
        value = value[:-1]
    return value


@lru_cache(maxsize=1)
def _issuer() -> str:
    configured = _get_env("KEYCLOAK_ISSUER")
    if configured:
        return configured
    url = _get_env("KEYCLOAK_URL", "http://localhost:8080")
    realm = _get_env("KEYCLOAK_REALM", "banking")
    return f"{url}/realms/{realm}"


@lru_cache(maxsize=1)
def _jwks_uri() -> str:
    url = _get_env("KEYCLOAK_URL", "http://localhost:8080")
    realm = _get_env("KEYCLOAK_REALM", "banking")
    return f"{url}/realms/{realm}/protocol/openid-connect/certs"


@lru_cache(maxsize=1)
def _audience() -> str:
    return _get_env("KEYCLOAK_AUDIENCE", "account")


_JWKS_TTL = 3600
_jwks_cache: Dict[str, Any] | None = None
_jwks_fetched_at: float = 0.0
_jwks_lock = threading.Lock()


def _jwks() -> Dict[str, Any]:
    global _jwks_cache, _jwks_fetched_at
    with _jwks_lock:
        if _jwks_cache is None or time.monotonic() - _jwks_fetched_at > _JWKS_TTL:
            try:
                with httpx.Client(timeout=5.0) as http:
                    resp = http.get(_jwks_uri())
                    resp.raise_for_status()
                    _jwks_cache = resp.json()
                    _jwks_fetched_at = time.monotonic()
            except Exception as exc:
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail="Unable to fetch Keycloak JWKS",
                ) from exc
        return _jwks_cache


def _public_key_for_kid(kid: str) -> Dict[str, Any]:
    for key in _jwks().get("keys", []):
        if key.get("kid") == kid:
            return key
    # Possible key rotation — invalidate cache and retry once
    global _jwks_cache
    with _jwks_lock:
        _jwks_cache = None
    for key in _jwks().get("keys", []):
        if key.get("kid") == kid:
            return key
    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token (unknown kid)")


def _decode_token(token: str) -> Dict[str, Any]:
    try:
        headers = jwt.get_unverified_header(token)
    except jwt.InvalidTokenError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token") from exc

    key = _public_key_for_kid(headers.get("kid", ""))
    try:
        payload = jwt.decode(
            token,
            key=jwt.algorithms.RSAAlgorithm.from_jwk(key),
            algorithms=["RS256"],
            issuer=_issuer(),
            options={"verify_aud": False},
        )
    except jwt.ExpiredSignatureError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token expired") from exc
    except jwt.InvalidIssuerError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid issuer") from exc
    except jwt.InvalidTokenError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token") from exc

    aud = payload.get("aud")
    expected = _audience()
    valid_aud = (aud == expected) if isinstance(aud, str) else (expected in aud if isinstance(aud, list) else False)
    if not valid_aud:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token audience")
    return payload


def require_user(authorization: str | None = Header(default=None, alias="Authorization")) -> UserContext:
    """FastAPI dependency — verifies JWT signature and returns a UserContext."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    payload = _decode_token(token)
    subject = payload.get("sub")
    user_id = payload.get("preferred_username") or payload.get("uid")
    if not subject or not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token must contain a subject and bank user ID",
        )
    return UserContext(user_id=str(user_id), subject=str(subject))
