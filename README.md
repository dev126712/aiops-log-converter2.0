# AIOps Log Converter 2.0

Production-ready log intelligence pipeline: **Loki → Isolation Forest → LLM explanation → MongoDB/Redis → Grafana**.

[![Python](https://skillicons.dev/icons?i=py,docker,prometheus,grafana,mongodb,redis)](https://skillicons.dev)

---

## How It Works

```
Docker containers
      │
      ▼ (Promtail scrapes container logs)
    Loki  ←────────────────────────────────────┐
      │                                         │
      ▼ (pipeline fetches every 5 min)          │
  [Fetch logs from Loki]                        │
      │                                         │
      ▼                                         │
  [Isolation Forest]  ← scikit-learn           │
  Anomaly scoring                               │
      │                                         │
      ├─ normal → skip (Redis dedup cache)       │
      │                                         │
      ▼ anomaly                                  │
  [LLM explanation]                             │
  Groq (Llama 3.3 70B) locally                 │
  Ollama on K8s GPU node                        │
      │                                         │
      ├──▶ MongoDB  (anomaly record)             │
      ├──▶ Redis    (dedup cache, LRU)           │
      └──▶ Webhook  (alert)                     │
                                                │
  Prometheus ◀─ pipeline metrics ──────────────┘
  Grafana    ◀─ pre-provisioned dashboards
```

---

## Stack

| Layer | Technology |
|---|---|
| **Log ingest** | Loki 2.9 · Promtail (Docker socket scraping) |
| **ML detection** | scikit-learn Isolation Forest (unsupervised, no labelled data needed) |
| **LLM** | Groq API (Llama 3.3 70B, free tier) · Ollama (local GPU) — auto-routed |
| **Cache** | Redis 7.2 (LRU eviction · AOF persistence · deduplication) |
| **Storage** | MongoDB 4.4 (anomaly records) |
| **Observability** | Prometheus 2.52 (pipeline metrics) · Grafana 10.4 (pre-provisioned dashboards) |
| **Containerisation** | Docker Compose (7 services, health-checked startup order) |

---

## Architecture Highlights

**Adapter pattern** — cache, storage, and alert backends are interfaces. Swap `RedisAdapter` for `NullCacheAdapter`, `MongoStorageAdapter` for `LogStorageAdapter`, or add a new alert destination without touching pipeline logic.

**LLM routing** — the pipeline checks whether an Ollama host is reachable at startup. If yes, it uses the local GPU node (K8s deployment). If no, it falls back to Groq's free API. No code changes needed when switching environments.

**Groq rate-limit handling** — exponential back-off with 3 retries built into the Groq client. Pipeline interval is 5 minutes by default, keeping usage comfortably within Groq's free tier (14,400 req/day).

---

## Quick Start

```bash
git clone https://github.com/dev126712/aiops-log-converter2.0
cd aiops-log-converter2.0
cp env.example .env
# Fill in: GROQ_API_KEY (get one free at console.groq.com)

docker compose up --build
```

Services come up in dependency order (Redis → MongoDB → Loki → Prometheus → Grafana → Promtail → pipeline).

| Service | URL |
|---|---|
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |
| Loki | http://localhost:3100 |

Inject sample logs to trigger anomaly detection:

```bash
bash inject_logs.sh
```

---

## Configuration

All configuration is via environment variables (`.env` file or `docker-compose.yml` override).

| Variable | Default | Description |
|---|---|---|
| `GROQ_API_KEY` | required | Free API key from console.groq.com |
| `GROQ_MODEL` | `llama-3.3-70b-versatile` | Groq model to use |
| `OLLAMA_HOST` | unset | Set to Ollama URL to prefer local GPU |
| `LOKI_URL` | `http://loki:3100` | Loki query endpoint |
| `PROMETHEUS_URL` | `http://prometheus:9090` | Prometheus endpoint |
| `REDIS_URI` | `redis://redis:6379/0` | Redis connection string |
| `MONGO_URI` | `mongodb://...` | MongoDB connection string |
| `FETCH_WINDOW_MINS` | `5` | How far back each pipeline run looks |
| `LOG_FETCH_LIMIT` | `200` | Max log lines per run |
| `PIPELINE_INTERVAL` | `300` | Seconds between pipeline runs |
| `DEPLOYMENT_ENV` | `server` | `local` disables some adapters for dev |

---

## Project Structure

```
aiops-log-converter2.0/
├── aiops_pipeline.py      # Full pipeline: fetch → score → explain → store → alert
├── Dockerfile
├── docker-compose.yml     # 7-service stack with health checks
├── requirements.txt
├── inject_logs.sh         # Sample log injector for local testing
├── sample_logs/           # Example log payloads
├── mongo-init/            # MongoDB init scripts
└── config/
    ├── loki-config.yaml
    ├── promtail-config.yaml
    ├── prometheus.yml
    └── grafana/
        └── provisioning/  # Auto-provisioned datasources and dashboards
```

---

## Compared to v1

| Feature | v1 | v2 |
|---|---|---|
| Log source | Static files | Loki (live Docker logs) |
| LLM | Gemini 1.5 Flash | Groq / Ollama (provider-agnostic) |
| Cache | None | Redis (LRU, AOF persistence) |
| Storage | None | MongoDB |
| Observability | None | Prometheus + Grafana (pre-provisioned) |
| Architecture | Linear script | Adapter pattern (swappable backends) |
| Rate-limit handling | None | Exponential back-off |
