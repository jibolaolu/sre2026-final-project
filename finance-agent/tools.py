"""Authenticated, read-only banking tools for FinanceAgent.

Tools the model can call:
  get_balance()                              — current account balance
  get_recent_transactions()                  — all transactions (newest first)
  get_spending_summary(period_days)          — income vs spending totals over N days
  search_transactions(keyword)               — full-text search over reference field
  get_transactions_by_type(transaction_type) — filter by DEPOSIT / WITHDRAWAL / TRANSFER_*
  calculate_affordability(amount)            — can the user afford a given spend?

All tools re-validate the bearer token on every call so a stale or forged
tool_context cannot bypass authentication.
"""
from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from typing import Any, Callable, Dict, Literal, Tuple
from urllib.parse import quote

import httpx
from fastapi import HTTPException, status
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from auth import exchange_token, user_from_token


def _tx_base() -> str:
    return os.getenv("TRANSACTION_API_URL", "").rstrip("/")


def _authorized_user(context: Dict[str, Any]) -> tuple[str, str]:
    token = context.get("token")
    if not isinstance(token, str) or not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="A valid bearer token is required for banking tools")
    user = user_from_token(token)
    if context.get("user_id") != user.user_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                            detail="Tool user does not match the authenticated token")
    return user.user_id, token


@retry(
    retry=retry_if_exception_type((httpx.ConnectError, httpx.TimeoutException)),
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=0.5, min=0.5, max=4),
    reraise=True,
)
def _http_get_raw(url: str, headers: dict) -> Any:
    """Raw HTTP GET — tenacity retries this on transient connect/timeout errors."""
    with httpx.Client(timeout=5.0) as http:
        resp = http.get(url, headers=headers)
        resp.raise_for_status()
        return resp.json()


def _fetch(context: Dict[str, Any], resource: Literal["balance", "transactions"]) -> tuple[str, Any]:
    user_id, token = _authorized_user(context)
    base = _tx_base()
    if not base:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                            detail="Transaction API is not configured")
    # Priority 2: exchange for a narrowed token scoped to transaction-service-client.
    # Falls back to the original user token when token exchange is not configured.
    tx_token = exchange_token(token)
    try:
        data = _http_get_raw(
            f"{base}/{resource}/{quote(user_id, safe='')}",
            {"Authorization": f"Bearer {tx_token}"},
        )
        return user_id, data
    except httpx.TimeoutException as exc:
        raise HTTPException(status_code=status.HTTP_504_GATEWAY_TIMEOUT,
                            detail="Transaction API timed out") from exc
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                            detail="Transaction API rejected the request") from exc
    except httpx.RequestError as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                            detail="Unable to reach the transaction API") from exc
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                            detail="Transaction API returned invalid JSON") from exc


def _parse_dt(value: Any) -> datetime | None:
    """Parse a LocalDateTime that Spring Boot may serialise as ISO string or int array."""
    if value is None:
        return None
    if isinstance(value, list) and len(value) >= 6:
        try:
            return datetime(*value[:6], tzinfo=timezone.utc)
        except (TypeError, ValueError):
            return None
    if isinstance(value, str):
        for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%d"):
            try:
                return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
            except ValueError:
                continue
    return None


def _fmt(amount: Any) -> str:
    try:
        return f"{Decimal(str(amount)):.2f}"
    except (InvalidOperation, TypeError):
        return str(amount)


def get_toolkit(context: Dict[str, Any] | None = None) -> Tuple[Dict[str, Callable[..., Any]], list[dict]]:
    ctx = context or {}

    # ── tool 1: current balance ───────────────────────────────────────────────

    def get_balance() -> Dict[str, Any]:
        user_id, data = _fetch(ctx, "balance")
        if not isinstance(data, dict) or data.get("balance") is None:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned no balance")
        try:
            balance = f"{Decimal(str(data['balance'])):.2f}"
        except (InvalidOperation, TypeError, ValueError) as exc:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned an invalid balance") from exc
        return {"account_id": user_id, "currency": "GBP", "balance": balance, "mock": False}

    # ── tool 2: recent transactions ───────────────────────────────────────────

    def get_recent_transactions() -> Dict[str, Any]:
        _, txns = _fetch(ctx, "transactions")
        if not isinstance(txns, list):
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned invalid transactions")
        return {"currency": "GBP", "mock": False, "count": len(txns), "transactions": txns}

    # ── tool 3: spending summary ──────────────────────────────────────────────

    def get_spending_summary(period_days: int = 30) -> Dict[str, Any]:
        """Aggregate income and spending over the last period_days days."""
        period_days = max(1, min(period_days, 365))
        cutoff = datetime.now(tz=timezone.utc) - timedelta(days=period_days)

        _, txns = _fetch(ctx, "transactions")
        if not isinstance(txns, list):
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned invalid transactions")

        income   = Decimal("0")
        spending = Decimal("0")
        by_type: dict[str, dict] = {}
        included = 0

        for t in txns:
            dt = _parse_dt(t.get("createdAt"))
            if dt and dt < cutoff:
                continue
            try:
                amt = Decimal(str(t.get("amount", 0)))
            except InvalidOperation:
                continue
            tx_type = (t.get("transactionType") or "UNKNOWN").upper()
            included += 1
            bucket = by_type.setdefault(tx_type, {"count": 0, "total": Decimal("0")})
            bucket["count"] += 1
            bucket["total"] += amt
            if tx_type in ("DEPOSIT", "TRANSFER_IN"):
                income += amt
            else:
                spending += abs(amt)

        return {
            "currency": "GBP",
            "period_days": period_days,
            "transactions_analysed": included,
            "total_income": _fmt(income),
            "total_spending": _fmt(spending),
            "net": _fmt(income - spending),
            "by_type": {k: {"count": v["count"], "total": _fmt(v["total"])} for k, v in by_type.items()},
        }

    # ── tool 4: keyword search ────────────────────────────────────────────────

    def search_transactions(keyword: str | None = None) -> Dict[str, Any]:
        """Search transactions whose reference contains keyword (case-insensitive)."""
        _authorized_user(ctx)
        if keyword is None:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                                detail="keyword is required")
        keyword = keyword.strip()
        if not keyword:
            return {"currency": "GBP", "count": 0, "matches": []}

        _, txns = _fetch(ctx, "transactions")
        if not isinstance(txns, list):
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned invalid transactions")

        needle  = keyword.lower()
        matches = [t for t in txns if needle in str(t.get("reference") or "").lower()]
        return {
            "currency": "GBP",
            "keyword": keyword,
            "count": len(matches),
            "matches": matches[:20],  # cap response size
        }

    # ── tool 5: filter by transaction type ───────────────────────────────────

    def get_transactions_by_type(transaction_type: str | None = None) -> Dict[str, Any]:
        """Return transactions of a specific type.

        Valid types: DEPOSIT, WITHDRAWAL, TRANSFER_IN, TRANSFER_OUT.
        """
        _authorized_user(ctx)
        if transaction_type is None:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                                detail="transaction_type is required")
        tx_type = transaction_type.strip().upper()
        valid   = {"DEPOSIT", "WITHDRAWAL", "TRANSFER_IN", "TRANSFER_OUT"}
        if tx_type not in valid:
            return {"error": f"Unknown type '{tx_type}'. Valid: {sorted(valid)}"}

        _, txns = _fetch(ctx, "transactions")
        if not isinstance(txns, list):
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned invalid transactions")

        filtered = [t for t in txns if (t.get("transactionType") or "").upper() == tx_type]
        total    = sum(Decimal(str(t.get("amount", 0))) for t in filtered
                       if isinstance(t.get("amount"), (int, float, str)))
        return {
            "currency": "GBP",
            "transaction_type": tx_type,
            "count": len(filtered),
            "total": _fmt(total),
            "transactions": filtered,
        }

    # ── tool 6: affordability check ───────────────────────────────────────────

    def calculate_affordability(amount: float | None = None) -> Dict[str, Any]:
        """Check whether the current balance covers a proposed spend amount."""
        _authorized_user(ctx)
        if amount is None:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                                detail="amount is required")
        try:
            proposed = Decimal(str(amount))
            if proposed <= 0:
                return {"error": "Amount must be a positive number"}
        except InvalidOperation:
            return {"error": "Invalid amount"}

        _, data = _fetch(ctx, "balance")
        if not isinstance(data, dict) or data.get("balance") is None:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned no balance")
        try:
            balance = Decimal(str(data["balance"]))
        except (InvalidOperation, TypeError) as exc:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned an invalid balance") from exc

        surplus = balance - proposed
        return {
            "currency": "GBP",
            "current_balance": _fmt(balance),
            "proposed_spend": _fmt(proposed),
            "remaining_after": _fmt(surplus),
            "can_afford": surplus >= 0,
            "note": (
                "Balance covers this amount, but upcoming bills and commitments are unknown."
                if surplus >= 0
                else "Insufficient balance for this amount."
            ),
        }

    # ── register tools ────────────────────────────────────────────────────────

    tool_functions: Dict[str, Callable[..., Any]] = {
        "get_balance":               get_balance,
        "get_recent_transactions":   get_recent_transactions,
        "get_spending_summary":      get_spending_summary,
        "search_transactions":       search_transactions,
        "get_transactions_by_type":  get_transactions_by_type,
        "calculate_affordability":   calculate_affordability,
    }

    tool_schemas = [
        {
            "type": "function",
            "name": "get_balance",
            "description": "Get the authenticated user's current account balance in GBP.",
            "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
            "strict": True,
        },
        {
            "type": "function",
            "name": "get_recent_transactions",
            "description": "Get all of the authenticated user's transactions, newest first.",
            "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
            "strict": True,
        },
        {
            "type": "function",
            "name": "get_spending_summary",
            "description": (
                "Summarise the user's income and spending totals over the last N days. "
                "Returns totals by transaction type and a net figure. Default is 30 days."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "period_days": {
                        "type": "integer",
                        "description": "Number of days to look back (1–365). Use 30 if the user does not specify.",
                    }
                },
                "required": ["period_days"],
                "additionalProperties": False,
            },
            "strict": True,
        },
        {
            "type": "function",
            "name": "search_transactions",
            "description": (
                "Search transactions whose reference description contains a keyword. "
                "Useful for 'did I pay Netflix?', 'show me supermarket transactions', etc."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "keyword": {
                        "type": "string",
                        "description": "The word or phrase to search for in transaction references.",
                    }
                },
                "required": ["keyword"],
                "additionalProperties": False,
            },
            "strict": True,
        },
        {
            "type": "function",
            "name": "get_transactions_by_type",
            "description": (
                "Filter the user's transactions to a specific type. "
                "Valid values: DEPOSIT, WITHDRAWAL, TRANSFER_IN, TRANSFER_OUT."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "transaction_type": {
                        "type": "string",
                        "description": "One of: DEPOSIT, WITHDRAWAL, TRANSFER_IN, TRANSFER_OUT.",
                    }
                },
                "required": ["transaction_type"],
                "additionalProperties": False,
            },
            "strict": True,
        },
        {
            "type": "function",
            "name": "calculate_affordability",
            "description": (
                "Check whether the user's current balance is sufficient for a proposed spend. "
                "Returns the remaining balance and a note about upcoming commitments."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "amount": {
                        "type": "number",
                        "description": "The proposed spend amount in GBP.",
                    }
                },
                "required": ["amount"],
                "additionalProperties": False,
            },
            "strict": True,
        },
    ]

    return tool_functions, tool_schemas
