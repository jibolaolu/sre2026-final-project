FROM python:3.12-slim

WORKDIR /app

# Upgrade OS packages to pick up latest security patches before installing deps.
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
# Remove pip after installation — pip is a build tool only; removing it eliminates
# pip CVEs from Trivy scans permanently without affecting runtime behaviour.
RUN pip install --upgrade "pip==26.2.2" \
    && pip install --no-cache-dir -r requirements.txt \
    && pip uninstall -y pip

COPY app ./app
COPY migrations ./migrations
COPY alembic.ini .

# Run alembic migrations then start uvicorn from app/ (so bare imports resolve correctly).
CMD ["sh", "-c", "alembic upgrade head && cd app && uvicorn main:app --host 0.0.0.0 --port 8000"]
