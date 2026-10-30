FROM python:3.12-slim

WORKDIR /app

# Upgrade OS packages to pick up latest security patches before installing deps.
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --upgrade "pip==26.1.2" && pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Run from inside the app/ directory so bare `from telemetry import ...`
# resolves to app/telemetry.py without needing the `app.` prefix.
WORKDIR /app/app
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
