"""Redis-backed conversation memory for the finance agent.

Each conversation lives under:
  finance-agent:history:{user_id}:{session_id}

The value is the JSON-serialised accumulated inputs list (the full context
passed to the OpenAI Responses API for a multi-turn conversation).
TTL defaults to 30 minutes so stale sessions are automatically evicted.

All operations degrade silently when Redis is unavailable — the agent
continues to work, just without cross-request memory.
"""
from __future__ import annotations

import json
import os
from typing import Any

_REDIS_URL   = os.getenv("REDIS_URL", "redis://redis:6379")
_SESSION_TTL = int(os.getenv("SESSION_TTL_SECONDS", "1800"))
_KEY_PREFIX  = "finance-agent:history"

_client: Any = None


def _get_client():
    global _client
    if _client is not None:
        return _client
    try:
        import redis
        c = redis.from_url(_REDIS_URL, decode_responses=True, socket_connect_timeout=2)
        c.ping()
        _client = c
    except Exception:
        _client = None
    return _client


def _key(user_id: str, session_id: str) -> str:
    return f"{_KEY_PREFIX}:{user_id}:{session_id}"


def load_history(user_id: str, session_id: str) -> list[dict]:
    """Return the stored input list for this session, or [] on any error."""
    if not user_id:
        return []
    r = _get_client()
    if r is None:
        return []
    try:
        raw = r.get(_key(user_id, session_id))
        return json.loads(raw) if raw else []
    except Exception:
        return []


def save_history(user_id: str, session_id: str, inputs: list) -> None:
    """Persist the inputs list; silently ignores serialisation or network errors."""
    if not user_id:
        return
    r = _get_client()
    if r is None:
        return
    try:
        r.setex(_key(user_id, session_id), _SESSION_TTL, json.dumps(inputs, default=str))
    except Exception:
        pass


def clear_session(user_id: str, session_id: str) -> bool:
    if not user_id:
        return False
    r = _get_client()
    if r is None:
        return False
    try:
        return bool(r.delete(_key(user_id, session_id)))
    except Exception:
        return False


def list_sessions(user_id: str) -> list[str]:
    if not user_id:
        return []
    r = _get_client()
    if r is None:
        return []
    try:
        prefix = f"{_KEY_PREFIX}:{user_id}:"
        keys   = r.keys(f"{prefix}*")
        return [k[len(prefix):] for k in keys]
    except Exception:
        return []


def clear_all_sessions(user_id: str) -> int:
    if not user_id:
        return 0
    r = _get_client()
    if r is None:
        return 0
    try:
        prefix = f"{_KEY_PREFIX}:{user_id}:"
        keys   = r.keys(f"{prefix}*")
        return int(r.delete(*keys)) if keys else 0
    except Exception:
        return 0
