# ============================================================
# AIOps Pipeline — Production Dockerfile
# Multi-stage build: keeps the final image ~40% smaller by
# leaving build tools, compilers, and wheel caches behind.
# ============================================================

# ── Stage 1: builder ─────────────────────────────────────────
FROM python:3.11-slim AS builder

# Build-time deps only (gcc needed for some C extensions in sklearn/numpy)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy and install into an isolated prefix so we can COPY only
# the installed packages into the final stage — no pip cache or
# compiler artifacts.
COPY requirements.txt .
RUN pip install --upgrade pip \
 && pip install --prefix=/install --no-cache-dir -r requirements.txt


# ── Stage 2: runtime ─────────────────────────────────────────
FROM python:3.11-slim AS runtime

LABEL maintainer="your-team@example.com" \
      version="1.0.0" \
      description="AIOps observability pipeline"

# Runtime-only OS packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \          
    # curl is used by the HEALTHCHECK below
    && rm -rf /var/lib/apt/lists/*

# ── Security: non-root user ───────────────────────────────────
RUN groupadd --gid 1001 aiops \
 && useradd  --uid 1001 --gid aiops --shell /bin/bash --create-home aiops

# Pull only the installed packages from the builder stage
COPY --from=builder /install /usr/local

WORKDIR /app

# Copy application source
COPY --chown=aiops:aiops aiops_pipeline.py .
COPY --chown=aiops:aiops .env.example .env.example

# Switch to non-root before the process starts
USER aiops

# ── Health check ─────────────────────────────────────────────
# The pipeline writes a heartbeat file after each successful run.
# Docker/K8s probes check its freshness (max age = 2 × run interval).
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD test $(find /tmp/aiops_heartbeat -mmin -10 2>/dev/null | wc -l) -gt 0 \
      || exit 1

# ── Default command ───────────────────────────────────────────
# Override in docker-compose / k8s manifest for different entry-points
# (lambda_handler, a FastAPI wrapper, etc.)
CMD ["python", "aiops_pipeline.py"]