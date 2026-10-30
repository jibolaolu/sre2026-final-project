FROM python:3.12-slim

WORKDIR /app

# Upgrade OS packages for security patches, then install build deps in the same layer.
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends gcc librdkafka-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --upgrade "pip==26.2.2" && pip install --no-cache-dir -r requirements.txt

COPY app ./app

WORKDIR /app/app
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
