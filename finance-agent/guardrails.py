"""Input / output guardrails for the finance agent.

check_input(message, user_id)
    Raises HTTP 422 on policy violations (injection, payment-action requests).
    Raises HTTP 429 when the per-user sliding-window rate limit is exceeded.

apply_output_guardrails(answer, message)
    Returns the answer unchanged, or with a regulatory disclaimer appended
    when the conversation touches investment / financial-advice territory.
"""
from __future__ import annotations

import re
import time
from collections import deque
from threading import Lock
from typing import Deque

from fastapi import HTTPException

# ── prompt-injection / jailbreak patterns ────────────────────────────────────
_INJECTION_PATTERNS = [
    r"ignore\s+(previous|above|prior|all)\s+instructions",
    r"\byou\s+are\s+now\b",
    r"\bpretend\s+(you\s+are|to\s+be)\b",
    r"\bjailbreak\b",
    r"\bDAN\s+mode\b",
    r"\bbypass\b.*\brules?\b",
    r"\bsystem\s+prompt\b",
    r"<\s*/?system\s*>",
    r"```\s*system",
    r"\bforget\s+(all\s+)?(previous\s+)?instructions\b",
]

# ── patterns that imply a payment or sensitive-data action ────────────────────
_ACTION_PATTERNS = [
    r"(transfer|send|move|wire|pay|withdraw|deposit)\s+[\£\$€]?\s*\d",
    r"\b(my|your|his|her)\s+(pin|password|cvv|secret\s*key)\b",
    r"\bcredit\s+card\s+number\b",
    r"\bsort\s+code\b.*\baccount\s+number\b",
    r"\bnational\s+insurance\s+number\b",
    r"\bsocial\s+security\s+number\b",
]

# ── topics that require a financial-advice disclaimer on the output ────────────
_ADVICE_TOPICS = [
    "invest", "stock", "equity", "share ", "fund", "bond",
    "crypto", "bitcoin", "ethereum", "portfolio", "returns",
    "yield", "should i buy", "dividend", "pension", " isa ",
    "retirement", "tax advantag", "hedge", "asset alloc",
]

_DISCLAIMER = (
    "\n\n---\n*For informational purposes only. This does not constitute "
    "financial, investment, or tax advice. Past performance is not indicative "
    "of future results. Please consult a qualified financial adviser before "
    "making investment decisions.*"
)

_INJECTION_RE = [re.compile(p, re.IGNORECASE | re.DOTALL) for p in _INJECTION_PATTERNS]
_ACTION_RE    = [re.compile(p, re.IGNORECASE | re.DOTALL) for p in _ACTION_PATTERNS]

# ── sliding-window rate limiter (in-process; Redis-based in a multi-replica env) ─
_RATE_LOCK    = Lock()
_RATE_WINDOWS: dict[str, Deque[float]] = {}
_RATE_LIMIT   = 10   # requests
_RATE_WINDOW  = 60   # seconds


def _rate_check(user_id: str) -> None:
    now = time.monotonic()
    with _RATE_LOCK:
        window: Deque[float] = _RATE_WINDOWS.setdefault(user_id, deque())
        while window and now - window[0] > _RATE_WINDOW:
            window.popleft()
        if len(window) >= _RATE_LIMIT:
            raise HTTPException(
                status_code=429,
                detail=f"Too many requests — limit is {_RATE_LIMIT} per {_RATE_WINDOW}s.",
            )
        window.append(now)


def check_input(message: str, user_id: str = "") -> None:
    """Raise HTTP 422 / 429 if the message violates any guardrail."""
    if user_id:
        _rate_check(user_id)

    for pattern in _INJECTION_RE:
        if pattern.search(message):
            raise HTTPException(
                status_code=422,
                detail="Message contains content that cannot be processed by the banking assistant.",
            )

    for pattern in _ACTION_RE:
        if pattern.search(message):
            raise HTTPException(
                status_code=422,
                detail="This assistant cannot perform payment operations or handle credential data. "
                       "Use the banking app for transactions.",
            )


def apply_output_guardrails(answer: str, message: str) -> str:
    """Append a regulatory disclaimer when investment/advice topics are detected."""
    combined = (message + " " + answer).lower()
    if any(topic in combined for topic in _ADVICE_TOPICS):
        return answer + _DISCLAIMER
    return answer
