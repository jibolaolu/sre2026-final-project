"""JWT auth for FinanceAgent using Keycloak.

Reads the Bearer token from the Authorization header, verifies the
signature against the Keycloak realm JWKS, and validates issuer and
expected audience. Returns a small user context with user_id and token.

Environment variables:
- KEYCLOAK_URL (Keycloak URL reachable from this service)
- KEYCLOAK_ISSUER (issuer URL present in access tokens)
- KEYCLOAK_REALM (e.g., banking)
- KEYCLOAK_AUDIENCE (e.g., account)
"""
from __future__ import annotations
import os
from functools import lru_cache
from typing import Any, Dict

import time
import threading

import httpx
from fastapi import Depends, Header, HTTPException, status
import jwt


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
    configured_issuer = _get_env("KEYCLOAK_ISSUER")
    if configured_issuer:
        return configured_issuer
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


_JWKS_TTL = 3600  # re-fetch at most once per hour; refreshes on Keycloak key rotation
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
            except Exception as exc:  # pragma: no cover (network issues)
                raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                                    detail="Unable to fetch Keycloak JWKS") from exc
        return _jwks_cache


def _public_key_for_kid(kid: str) -> Dict[str, Any]:
    jwks = _jwks()
    for key in jwks.get("keys", []):
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
            audience=None,  # validate manually to accept list or string
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
    if isinstance(aud, str):
        valid_aud = (aud == expected)
    elif isinstance(aud, list):
        valid_aud = expected in aud
    else:
        valid_aud = False
    if not valid_aud:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token audience")
    return payload


def user_from_token(token: str) -> UserContext:
    payload = _decode_token(token)
    subject = payload.get("sub")
    user_id = payload.get("preferred_username") or payload.get("uid")
    if not subject or not user_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Token must contain a subject and bank user ID")
    return UserContext(user_id=str(user_id), subject=str(subject), token=token)


def require_user(authorization: str | None = Header(default=None, alias="Authorization")) -> UserContext:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    return user_from_token(token)


def require_ai_agent_user(authorization: str | None = Header(default=None, alias="Authorization")) -> UserContext:
    """Like require_user but also enforces the banking-ai-agent realm role (A11)."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")

    payload = _decode_token(token)
    subject = payload.get("sub")
    user_id = payload.get("preferred_username") or payload.get("uid")
    if not subject or not user_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Token must contain a subject and bank user ID")

    roles: list[str] = payload.get("realm_access", {}).get("roles", [])
    if "banking-ai-agent" not in roles:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Access requires the banking-ai-agent role",
        )

    return UserContext(user_id=str(user_id), subject=str(subject), token=token)


# Helper for tests to bypass network/keycloak by overriding the dependency
def fake_user(user_id: str = "test-user") -> UserContext:  # pragma: no cover
    return UserContext(user_id=user_id, subject="test-subject", token="test-token")


def exchange_token(user_token: str, audience: str = "transaction-service-client") -> str:
    """Exchange a user access token for a narrowed-scope token via RFC 8693 token exchange.

    Requires FINANCE_AGENT_KC_SECRET to be set; falls back to the original token on any
    error (missing secret, Keycloak unreachable, feature not enabled).
    """
    import logging
    client_secret = _get_env("FINANCE_AGENT_KC_SECRET")
    if not client_secret:
        return user_token

    keycloak_url = _get_env("KEYCLOAK_URL", "http://localhost:8080")
    realm        = _get_env("KEYCLOAK_REALM", "banking")
    client_id    = _get_env("KEYCLOAK_CLIENT_ID", "finance-agent-client")

    try:
        with httpx.Client(timeout=5.0) as http:
            resp = http.post(
                f"{keycloak_url}/realms/{realm}/protocol/openid-connect/token",
                data={
                    "grant_type":         "urn:ietf:params:oauth:grant-type:token-exchange",
                    "client_id":          client_id,
                    "client_secret":      client_secret,
                    "subject_token":      user_token,
                    "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
                    "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
                    "audience":           audience,
                },
            )
            resp.raise_for_status()
            return resp.json()["access_token"]
    except Exception as exc:
        logging.getLogger(__name__).warning(
            "Token exchange failed (audience=%s): %s — using original token", audience, exc
        )
        return user_token


def get_rpt(user_token: str, audience: str = "transaction-service-client") -> str:
    """Request an RPT (Requesting Party Token) from Keycloak's UMA ticket endpoint.

    Falls back to the original token when Keycloak Authorization Services are not enabled
    or the request fails for any reason.
    """
    import logging
    keycloak_url = _get_env("KEYCLOAK_URL", "http://localhost:8080")
    realm        = _get_env("KEYCLOAK_REALM", "banking")

    try:
        with httpx.Client(timeout=5.0) as http:
            resp = http.post(
                f"{keycloak_url}/realms/{realm}/protocol/openid-connect/token",
                data={
                    "grant_type": "urn:ietf:params:oauth:grant-type:uma-ticket",
                    "audience":   audience,
                },
                headers={"Authorization": f"Bearer {user_token}"},
            )
            resp.raise_for_status()
            return resp.json()["access_token"]
    except Exception as exc:
        logging.getLogger(__name__).warning(
            "RPT request failed (audience=%s): %s — using original token", audience, exc
        )
        return user_token
