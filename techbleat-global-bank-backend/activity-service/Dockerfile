# Build stage: needs gcc + librdkafka-dev to compile the confluent-kafka C extension.
# These are build-only tools — they are NOT copied to the final image.
FROM python:3.12-slim AS builder

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc librdkafka-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
# Remove pip after building — pip is a build tool only; removing it eliminates
# pip CVEs from Trivy scans permanently without affecting runtime behaviour.
RUN pip install --upgrade "pip==26.2.2" \
    && pip install --no-cache-dir -r requirements.txt \
    && pip uninstall -y pip


# Runtime stage: minimal image with OS security patches + only librdkafka1 (runtime lib).
# gcc, librdkafka-dev headers, and all build tools are absent.
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends librdkafka1 \
    && rm -rf /var/lib/apt/lists/*

# Copy installed Python packages from build stage (no pip dist-info included).
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

COPY app ./app

WORKDIR /app/app
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
