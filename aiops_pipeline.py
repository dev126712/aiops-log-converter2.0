import time
import os
import json
import logging
import requests
import pandas as pd
from abc import ABC, abstractmethod
from datetime import datetime, timedelta
from typing import Optional

from sklearn.ensemble import IsolationForest
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(levelname)s | %(name)s | %(message)s")
logger = logging.getLogger("aiops")


# ---------------------------------------------------------------------------
# 1. CONFIG
# ---------------------------------------------------------------------------

class Config:
    LOKI_URL          = os.getenv("LOKI_URL",          "http://loki:3100")
    PROMETHEUS_URL    = os.getenv("PROMETHEUS_URL",    "http://prometheus:9090")
    REDIS_URI         = os.getenv("REDIS_URI",         "redis://localhost:6379/0")
    MONGO_URI         = os.getenv("MONGO_URI",         "mongodb://localhost:27017/")
    GROQ_API_KEY      = os.getenv("GROQ_API_KEY")
    GROQ_MODEL        = os.getenv("GROQ_MODEL",        "llama-3.3-70b-versatile")
    ALERT_WEBHOOK_URL = os.getenv("ALERT_WEBHOOK_URL")
    LOKI_QUERY        = os.getenv("LOKI_QUERY",        '{job="fluent-bit"}')
    FETCH_WINDOW_MINS = int(os.getenv("FETCH_WINDOW_MINS", "5"))
    LOG_FETCH_LIMIT   = int(os.getenv("LOG_FETCH_LIMIT",   "200"))
    REQUEST_TIMEOUT   = int(os.getenv("REQUEST_TIMEOUT",   "10"))
    PIPELINE_INTERVAL = int(os.getenv("PIPELINE_INTERVAL", "300"))  # seconds between runs
    DEPLOYMENT_ENV    = os.getenv("DEPLOYMENT_ENV",    "server")

    # Future: swap GROQ_API_KEY for OLLAMA_HOST when on Kubernetes GPU node
    OLLAMA_HOST  = os.getenv("OLLAMA_HOST",  "http://ollama-service:11434")
    OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.1:70b")

    @classmethod
    def is_serverless(cls) -> bool:
        return cls.DEPLOYMENT_ENV == "serverless"

    @classmethod
    def is_kubernetes(cls) -> bool:
        return cls.DEPLOYMENT_ENV == "kubernetes"


# ---------------------------------------------------------------------------
# 2. CONNECTION ADAPTERS
# ---------------------------------------------------------------------------

class CacheAdapter(ABC):
    @abstractmethod
    def get(self, key: str) -> Optional[str]: ...
    @abstractmethod
    def set(self, key: str, value: str, ttl: int = 300): ...


class RedisAdapter(CacheAdapter):
    def __init__(self):
        self._client = None

    def _client_or_connect(self):
        if self._client is None:
            import redis
            self._client = redis.from_url(Config.REDIS_URI, decode_responses=True)
        return self._client

    def get(self, key: str) -> Optional[str]:
        try:
            return self._client_or_connect().get(key)
        except Exception as e:
            logger.warning(f"Redis GET failed: {e}")
            return None

    def set(self, key: str, value: str, ttl: int = 300):
        try:
            self._client_or_connect().setex(key, ttl, value)
        except Exception as e:
            logger.warning(f"Redis SET failed: {e}")


class NullCacheAdapter(CacheAdapter):
    def get(self, key: str) -> Optional[str]: return None
    def set(self, key: str, value: str, ttl: int = 300):
        logger.warning("NullCacheAdapter active — no caching. Set REDIS_URI to enable.")


class StorageAdapter(ABC):
    @abstractmethod
    def save_anomalies(self, anomalies: list): ...


class MongoStorageAdapter(StorageAdapter):
    def __init__(self):
        self._client = None

    def _db(self):
        if self._client is None:
            from pymongo import MongoClient
            self._client = MongoClient(
                Config.MONGO_URI,
                serverSelectionTimeoutMS=3000,
            )
        return self._client["aiops"]

    def save_anomalies(self, anomalies: list):
        try:
            self._db()["anomalies"].insert_many(anomalies)
            logger.info(f"Saved {len(anomalies)} anomaly records to MongoDB.")
        except Exception as e:
            logger.warning(f"MongoDB write failed: {e}")


class LogStorageAdapter(StorageAdapter):
    def save_anomalies(self, anomalies: list):
        logger.warning(f"Anomalies (log-only storage): {json.dumps(anomalies, default=str)}")


class AlertAdapter(ABC):
    @abstractmethod
    def send(self, message: str): ...


class WebhookAlertAdapter(AlertAdapter):
    def send(self, message: str):
        if not Config.ALERT_WEBHOOK_URL:
            logger.info(f"[ALERT — no webhook configured] {message}")
            return
        try:
            requests.post(
                Config.ALERT_WEBHOOK_URL,
                json={"text": message},
                timeout=Config.REQUEST_TIMEOUT,
            )
            logger.info("Alert dispatched via webhook.")
        except Exception as e:
            logger.warning(f"Webhook alert failed: {e}")


# ---------------------------------------------------------------------------
# 3. ADAPTER FACTORY
# ---------------------------------------------------------------------------

def build_cache() -> CacheAdapter:
    if Config.REDIS_URI:
        return RedisAdapter()
    return NullCacheAdapter()


def build_storage() -> StorageAdapter:
    if Config.MONGO_URI:
        return MongoStorageAdapter()
    return LogStorageAdapter()


def build_alert() -> AlertAdapter:
    return WebhookAlertAdapter()


# ---------------------------------------------------------------------------
# 4. LLM CLIENT
#
# LOCAL DEV  → Groq (free API, Llama 3.3 70B, 14,400 req/day)
# KUBERNETES → Ollama on GPU node (swap GROQ_API_KEY → OLLAMA_HOST in env)
# ---------------------------------------------------------------------------

def call_groq(prompt: str) -> str:
    """
    Calls Groq's free API — OpenAI-compatible endpoint.
    30 RPM / 14,400 RPD on free tier.
    Set GROQ_API_KEY in .env — get key at https://console.groq.com
    """
    if not Config.GROQ_API_KEY:
        raise EnvironmentError("GROQ_API_KEY is not set. Get a free key at https://console.groq.com")

    url = "https://api.groq.com/openai/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {Config.GROQ_API_KEY}",
        "Content-Type": "application/json"
    }
    payload = {
        "model": Config.GROQ_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 4000,
        "temperature": 0.1    # low temp = more deterministic JSON output
    }

    for attempt in range(3):
        res = requests.post(url, headers=headers, json=payload, timeout=30)
        if res.status_code == 429:
            wait = 60 * (attempt + 1)   # 60s, 120s, 180s
            logger.warning(f"Groq rate limited — waiting {wait}s before retry {attempt + 1}/3")
            time.sleep(wait)
            continue
        res.raise_for_status()
        return res.json()["choices"][0]["message"]["content"]

    raise Exception("Groq rate limit exceeded after 3 retries")


def call_ollama(prompt: str) -> str:
    """
    Calls local Ollama — used in Kubernetes on the GPU node.
    Switch by setting OLLAMA_HOST and unsetting GROQ_API_KEY.
    """
    url = f"{Config.OLLAMA_HOST}/api/generate"
    payload = {
        "model":  Config.OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.1}
    }
    res = requests.post(url, json=payload, timeout=120)
    res.raise_for_status()
    return res.json()["response"]


def call_llm(prompt: str) -> str:
    """
    Router — uses Ollama if OLLAMA_HOST is reachable, otherwise Groq.
    In practice: Groq locally, Ollama on K8s GPU node.
    """
    if Config.DEPLOYMENT_ENV == "kubernetes":
        return call_ollama(prompt)
    return call_groq(prompt)


# ---------------------------------------------------------------------------
# 5. OBSERVABILITY FETCHER
# ---------------------------------------------------------------------------

class ObservabilityFetcher:
    def __init__(self, cache: CacheAdapter):
        self.cache = cache

    def _time_range(self, minutes: int):
        end = datetime.utcnow()
        start = end - timedelta(minutes=minutes)
        return start, end

    def fetch_loki_logs(self, minutes: int = None) -> list[str]:
        minutes = minutes or Config.FETCH_WINDOW_MINS
        cache_key = f"loki_logs:{minutes}"
        cached = self.cache.get(cache_key)
        if cached:
            return json.loads(cached)

        start, end = self._time_range(minutes)
        try:
            res = requests.get(
                f"{Config.LOKI_URL}/loki/api/v1/query_range",
                params={
                    "query": Config.LOKI_QUERY,
                    "start": int(start.timestamp() * 1e9),
                    "end":   int(end.timestamp() * 1e9),
                    "limit": Config.LOG_FETCH_LIMIT,
                },
                timeout=Config.REQUEST_TIMEOUT,
            )
            res.raise_for_status()
            logs = [
                entry[1]
                for stream in res.json()["data"]["result"]
                for entry in stream["values"]
            ]
            self.cache.set(cache_key, json.dumps(logs), ttl=60)
            return logs
        except Exception as e:
            logger.warning(f"Loki fetch failed: {e}")
            return []

    def fetch_prometheus_metrics(self, minutes: int = None) -> str:
        minutes = minutes or Config.FETCH_WINDOW_MINS
        cache_key = f"prom_metrics:{minutes}"
        cached = self.cache.get(cache_key)
        if cached:
            return cached

        query = "avg(rate(process_cpu_seconds_total[1m])) * 100"
        try:
            res = requests.get(
                f"{Config.PROMETHEUS_URL}/api/v1/query",
                params={"query": query},
                timeout=Config.REQUEST_TIMEOUT,
            )
            res.raise_for_status()
            results = res.json().get("data", {}).get("result", [])
            if results:
                metric = f"Average CPU Load: {round(float(results[0]['value'][1]), 2)}%"
                self.cache.set(cache_key, metric, ttl=60)
                return metric
        except Exception as e:
            logger.warning(f"Prometheus fetch failed: {e}")
        return "CPU metric unavailable"

    def fetch_all(self, minutes: int = None) -> dict:
        minutes = minutes or Config.FETCH_WINDOW_MINS
        return {
            "logs":    self.fetch_loki_logs(minutes),
            "metrics": self.fetch_prometheus_metrics(minutes),
        }


# ---------------------------------------------------------------------------
# 6. AI NORMALIZATION + ANOMALY DETECTION
# ---------------------------------------------------------------------------

def normalize_logs(observability_data: dict) -> pd.DataFrame:
    logs    = "\n".join(observability_data["logs"])
    metrics_text = observability_data["metrics"]

    # Guard: IsolationForest needs at least 10 samples to be meaningful
    if len(logs) < 10:
        logger.warning(f"Too few log lines ({len(logs)}) — skipping normalization")
        return pd.DataFrame()

    logs = logs[-50:]
    logs_text = "\n".join(logs)

    prompt = f"""
    You are an AIOps expert. Analyze the system state below and return ONLY a
    valid JSON array — no markdown, no explanation, no code fences.
    Each element must have exactly these three fields:
    - "level_score": integer 1-4 (INFO=1, WARN=2, ERROR=3, FATAL=4)
    - "msg_length": integer (character count of the log line)
    - "cpu_severity": integer 1-5 (1=idle, 5=critically overloaded)

    Return one JSON object per log line. Example output format:
    [{{"level_score": 1, "msg_length": 45, "cpu_severity": 1}}, ...]

    System Metrics: {metrics_text}
    System Logs (last {Config.FETCH_WINDOW_MINS} min):
    {logs_text}
    """

    try:
        raw = call_llm(prompt).strip()
        logger.info(f"RAW LLM RESPONSE: {repr(raw[:500])}")
        # Strip markdown fences — handle ```json, ```JSON, ``` etc.
        if "```" in raw:
            parts = raw.split("```")
            # Find the part that looks like JSON (starts with [ or {)
            for part in parts:
                part = part.lstrip("json").lstrip("JSON").strip()
                if part.startswith("[") or part.startswith("{"):
                    raw = part
                    break
        # Also strip any trailing explanation text after the JSON array
        if raw.startswith("["):
            end = raw.rfind("]")
            if end != -1:
                raw = raw[:end+1]
        import io
        if not raw.endswith("]"):
            last_complete = raw.rfind("},")
            if last_complete != -1:
                raw = raw[:last_complete+1] + "]"
            else:
                raise ValueError(f"Response truncated and unrecoverable")
        df = pd.read_json(io.StringIO(raw))
        logger.info(f"LLM normalized {len(df)} log entries successfully")
        return df
    except Exception as e:
        logger.error(f"LLM normalization failed: {e}")
        return pd.DataFrame()


def detect_anomalies(df: pd.DataFrame, storage: StorageAdapter, alert: AlertAdapter):
    if df.empty:
        logger.info("No data to evaluate.")
        return

    required = {"level_score", "msg_length", "cpu_severity"}
    if not required.issubset(df.columns):
        logger.error(f"DataFrame missing expected columns: {required - set(df.columns)}")
        return

    iso = IsolationForest(contamination=0.1, random_state=42)
    df = df.copy()
    df["anomaly"] = iso.fit_predict(df[list(required)])

    anomaly_rows = df[df["anomaly"] == -1]
    if anomaly_rows.empty:
        logger.info("No anomalies detected.")
        return

    records = anomaly_rows.assign(detected_at=datetime.utcnow().isoformat()).to_dict("records")
    storage.save_anomalies(records)
    alert.send(
        f"🚨 AIOps Alert: {len(records)} anomalies detected "
        f"across logs and metrics. Worst level_score: "
        f"{int(anomaly_rows['level_score'].max())}, "
        f"CPU severity: {int(anomaly_rows['cpu_severity'].max())}/5."
    )


# ---------------------------------------------------------------------------
# 7. CORE PIPELINE
# ---------------------------------------------------------------------------

def run_pipeline():
    cache   = build_cache()
    storage = build_storage()
    alert   = build_alert()

    fetcher = ObservabilityFetcher(cache=cache)
    data    = fetcher.fetch_all()

    if not data["logs"]:
        logger.info("No logs in window — pipeline exiting early.")
        return

    structured = normalize_logs(data)
    detect_anomalies(structured, storage=storage, alert=alert)

    logger.info(f"Pipeline run complete — sleeping {Config.PIPELINE_INTERVAL}s")
    time.sleep(Config.PIPELINE_INTERVAL)


# ---------------------------------------------------------------------------
# 8. ENTRYPOINTS
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    run_pipeline()


def lambda_handler(event, context):
    run_pipeline()
    return {"statusCode": 200, "body": "Pipeline complete."}
