"""
OpenTelemetry + structured logging initialisation.

Call configure_telemetry(service_name) once at module level before creating
the FastAPI app.  When OTEL_EXPORTER_OTLP_ENDPOINT is unset the function is a
no-op and get_logger() returns a standard Python logger, so the service runs
normally in local dev without an OTel collector.
"""
from __future__ import annotations
import json
import logging
import os
import sys
import time
from typing import Any

_SDK_INITIALISED = False


def configure_telemetry(service_name: str) -> None:
    global _SDK_INITIALISED
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")
    if not endpoint:
        _SDK_INITIALISED = False
        return

    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource, SERVICE_NAME
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
    try:
        from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
        SQLAlchemyInstrumentor().instrument()
    except ImportError:
        pass

    resource = Resource.create({SERVICE_NAME: service_name})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=True)))
    trace.set_tracer_provider(provider)
    FastAPIInstrumentor().instrument()
    HTTPXClientInstrumentor().instrument()
    _SDK_INITIALISED = True


class _JsonFormatter(logging.Formatter):
    def __init__(self, service_name: str) -> None:
        super().__init__()
        self._service = service_name

    def format(self, record: logging.LogRecord) -> str:
        try:
            from opentelemetry import trace
            span = trace.get_current_span()
            ctx = span.get_span_context()
            trace_id = format(ctx.trace_id, "032x") if ctx.is_valid else ""
            span_id  = format(ctx.span_id,  "016x") if ctx.is_valid else ""
        except Exception:
            trace_id = span_id = ""

        payload: dict[str, Any] = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level":     record.levelname,
            "service":   self._service,
            "message":   record.getMessage(),
        }
        if trace_id:
            payload["trace_id"] = trace_id
            payload["span_id"]  = span_id
        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)
        # merge any extra dict passed as `extra={"key": val}`
        for k, v in record.__dict__.items():
            if k not in logging.LogRecord.__dict__ and k not in payload:
                payload[k] = v
        return json.dumps(payload)


def get_logger(service_name: str) -> logging.Logger:
    logger = logging.getLogger(service_name)
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(_JsonFormatter(service_name))
        logger.addHandler(handler)
        logger.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
        logger.propagate = False
    return logger
