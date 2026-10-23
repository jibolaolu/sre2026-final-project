"""Start with: uvicorn main:app --reload --port 9001"""
from dotenv import load_dotenv
load_dotenv()

from telemetry import configure_telemetry, get_logger

_SERVICE_NAME = "finance-agent"
configure_telemetry(_SERVICE_NAME)
logger = get_logger(_SERVICE_NAME)

import json as _json

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, field_validator
from openai import OpenAIError
try:
    from anthropic import APIError as AnthropicAPIError
    _MODEL_ERRORS: tuple = (OpenAIError, AnthropicAPIError)
except ImportError:
    _MODEL_ERRORS = (OpenAIError,)

from agent import run_agent, stream_agent_tokens
from auth import require_ai_agent_user, require_user, UserContext
from guardrails import apply_output_guardrails, check_input
from memory import clear_all_sessions, clear_session, list_sessions

app = FastAPI(title="FinanceAgent — Techbleat Bank")

# ── Prometheus metrics ─────────────────────────────────────────────────────────
try:
    from prometheus_fastapi_instrumentator import Instrumentator
    Instrumentator().instrument(app).expose(app)
except ImportError:
    pass


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=2000)
    session_id: str = Field(default="", max_length=128)

    @field_validator("message")
    @classmethod
    def nonempty(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Message cannot be blank")
        return value

    @field_validator("session_id")
    @classmethod
    def sanitise_session(cls, value: str) -> str:
        # Allow only alphanumeric, hyphen, underscore to prevent key injection.
        import re
        return re.sub(r"[^a-zA-Z0-9\-_]", "", value)[:128]


# ── Health ─────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/me")
def me(user: UserContext = Depends(require_user)):
    return {"user_id": user.user_id}


# ── Chat ───────────────────────────────────────────────────────────────────────

@app.post("/chat")
def chat(request: ChatRequest, user: UserContext = Depends(require_ai_agent_user)):
    logger.info("Chat request received", extra={"user_id": user.user_id,
                                                "session_id": request.session_id})
    # Input guardrails: injection check, rate limit
    check_input(request.message, user.user_id)

    try:
        result = run_agent(
            request.message,
            user_id=user.user_id,
            session_id=request.session_id,
            tool_context={"user_id": user.user_id, "token": user.get("token")},
        )
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except _MODEL_ERRORS as exc:
        logger.warning("Model API request failed", extra={"error_type": type(exc).__name__, "error": str(exc)})
        raise HTTPException(
            status_code=502,
            detail="Model API request failed. Check your API key, model access and connectivity.",
        ) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    # Output guardrails: append financial disclaimer when needed.
    result["answer"] = apply_output_guardrails(result["answer"], request.message)
    return result


# ── Streaming chat ─────────────────────────────────────────────────────────────

@app.post("/chat/stream")
async def chat_stream(request: ChatRequest, user: UserContext = Depends(require_ai_agent_user)):
    """Stream the agent response as Server-Sent Events.

    Each event is a JSON object on a ``data:`` line. Event types:
    - ``{"type": "token",      "text": "..."}``       — partial response text
    - ``{"type": "tool_start", "tool": "<name>"}``    — tool invocation started
    - ``{"type": "tool_end",   "tool": "<name>"}``    — tool invocation finished
    - ``{"type": "done",       "session_id": "...", "mock_data": bool}``
    - ``{"type": "error",      "message": "..."}``
    - ``data: [DONE]`` — stream terminator
    """
    logger.info("Stream chat request received", extra={"user_id": user.user_id,
                                                       "session_id": request.session_id})
    check_input(request.message, user.user_id)

    async def event_generator():
        full_answer_parts: list[str] = []
        try:
            async for event in stream_agent_tokens(
                request.message,
                user_id=user.user_id,
                session_id=request.session_id,
                tool_context={"user_id": user.user_id, "token": user.get("token")},
            ):
                if event.get("type") == "token":
                    full_answer_parts.append(event["text"])
                    yield f"data: {_json.dumps(event)}\n\n"
                elif event.get("type") == "done":
                    # Apply output guardrails; if a disclaimer was appended, stream it.
                    full_answer = "".join(full_answer_parts)
                    guarded = apply_output_guardrails(full_answer, request.message)
                    if guarded != full_answer:
                        suffix = guarded[len(full_answer):]
                        yield f"data: {_json.dumps({'type': 'token', 'text': suffix})}\n\n"
                    yield f"data: {_json.dumps(event)}\n\n"
                    break
                else:
                    yield f"data: {_json.dumps(event)}\n\n"
        except _MODEL_ERRORS as exc:
            logger.warning("Model API error during streaming", extra={"error": str(exc)})
            yield f"data: {_json.dumps({'type': 'error', 'message': 'Model API request failed.'})}\n\n"
        except Exception as exc:  # noqa: BLE001
            logger.warning("Unexpected error during streaming", extra={"error": str(exc)})
            yield f"data: {_json.dumps({'type': 'error', 'message': str(exc)})}\n\n"
        finally:
            yield "data: [DONE]\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ── Session management ─────────────────────────────────────────────────────────

@app.get("/sessions")
def get_sessions(user: UserContext = Depends(require_ai_agent_user)):
    """List all active session IDs for the authenticated user."""
    return {"user_id": user.user_id, "sessions": list_sessions(user.user_id)}


@app.delete("/sessions/{session_id}")
def delete_session(session_id: str, user: UserContext = Depends(require_ai_agent_user)):
    """Delete a specific conversation session."""
    import re
    clean_id = re.sub(r"[^a-zA-Z0-9\-_]", "", session_id)[:128]
    if not clean_id:
        raise HTTPException(status_code=400, detail="Invalid session_id")
    deleted = clear_session(user.user_id, clean_id)
    return {"deleted": deleted, "session_id": clean_id}


@app.delete("/sessions")
def delete_all_sessions(user: UserContext = Depends(require_ai_agent_user)):
    """Delete all conversation sessions for the authenticated user."""
    count = clear_all_sessions(user.user_id)
    return {"deleted_count": count}
