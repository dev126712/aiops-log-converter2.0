FROM python:3.11-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY requirements.txt .
RUN pip install --upgrade pip \
 && pip install --prefix=/install --no-cache-dir -r requirements.txt


FROM python:3.11-slim AS runtime

LABEL maintainer="your-team@example.com" \
      version="1.0.0" \
      description="AIOps observability pipeline"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \          
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1001 aiops \
 && useradd  --uid 1001 --gid aiops --shell /bin/bash --create-home aiops

COPY --from=builder /install /usr/local

WORKDIR /app

COPY --chown=aiops:aiops aiops_pipeline.py .
COPY --chown=aiops:aiops .env.example .env.example

USER aiops

# The pipeline writes a heartbeat file after each successful run.
# Docker/K8s probes check its freshness (max age = 2 × run interval).
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD test $(find /tmp/aiops_heartbeat -mmin -10 2>/dev/null | wc -l) -gt 0 \
      || exit 1

# Override in docker-compose / k8s manifest for different entry-points
# (lambda_handler, a FastAPI wrapper, etc.)
CMD ["python", "aiops_pipeline.py"]