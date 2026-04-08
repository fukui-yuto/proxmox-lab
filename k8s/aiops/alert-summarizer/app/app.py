"""
alert-summarizer: AlertManager webhook → Claude API → Grafana Annotation / Slack
"""
import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

import anthropic
import httpx
from elasticsearch import Elasticsearch
from fastapi import BackgroundTasks, FastAPI
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

# ─── Configuration ────────────────────────────────────────────────────────────
ES_URL = os.getenv("ES_URL", "http://elasticsearch-master.logging.svc.cluster.local:9200")
GRAFANA_URL = os.getenv("GRAFANA_URL", "http://monitoring-grafana.monitoring.svc.cluster.local")
GRAFANA_USER = os.getenv("GRAFANA_USER", "admin")
GRAFANA_PASSWORD = os.getenv("GRAFANA_PASSWORD", "changeme")
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL", "")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
CLAUDE_MODEL = os.getenv("CLAUDE_MODEL", "claude-haiku-4-5-20251001")
ES_INDEX_PATTERN = os.getenv("ES_INDEX_PATTERN", "fluent-bit-*")
LOG_LOOKBACK_MINUTES = int(os.getenv("LOG_LOOKBACK_MINUTES", "15"))
MAX_LOG_SAMPLES = int(os.getenv("MAX_LOG_SAMPLES", "20"))

# ─── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(title="alert-summarizer", version="1.0.0")


# ─── Schemas ──────────────────────────────────────────────────────────────────
class AlertmanagerPayload(BaseModel):
    version: str = "4"
    groupKey: str = ""
    status: str = "firing"
    receiver: str = ""
    groupLabels: dict[str, Any] = {}
    commonLabels: dict[str, Any] = {}
    commonAnnotations: dict[str, Any] = {}
    externalURL: str = ""
    alerts: list[dict[str, Any]] = []


# ─── Routes ───────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/webhook")
async def webhook(payload: AlertmanagerPayload, background_tasks: BackgroundTasks):
    firing = [a for a in payload.alerts if a.get("status") == "firing"]
    if not firing:
        return {"status": "no firing alerts, skipped"}
    names = [a["labels"].get("alertname", "?") for a in firing]
    logger.info(f"Received {len(firing)} firing alert(s): {names}")
    background_tasks.add_task(process_alerts, payload)
    return {"status": "accepted", "alert_count": len(firing)}


# ─── Processing ───────────────────────────────────────────────────────────────
async def process_alerts(payload: AlertmanagerPayload) -> None:
    try:
        firing = [a for a in payload.alerts if a.get("status") == "firing"]
        logs = fetch_recent_logs()
        summary = await generate_summary(firing, logs)
        logger.info(f"Generated summary (first 200 chars): {summary[:200]}")

        if GRAFANA_URL:
            await post_grafana_annotation(summary, firing)
        if SLACK_WEBHOOK_URL:
            await post_slack(summary, firing)
    except Exception as e:
        logger.error(f"process_alerts failed: {e}", exc_info=True)


def fetch_recent_logs() -> list[str]:
    """Elasticsearch から直近のエラーログサンプルを取得する"""
    try:
        es = Elasticsearch(ES_URL, request_timeout=10)
        since = datetime.now(timezone.utc) - timedelta(minutes=LOG_LOOKBACK_MINUTES)
        resp = es.search(
            index=ES_INDEX_PATTERN,
            body={
                "size": MAX_LOG_SAMPLES,
                "sort": [{"@timestamp": "desc"}],
                "query": {
                    "bool": {
                        "must": [
                            {"range": {"@timestamp": {"gte": since.isoformat()}}},
                            {
                                "terms": {
                                    "log.level": [
                                        "error", "ERROR", "warn", "WARN",
                                        "critical", "CRITICAL", "fatal", "FATAL",
                                    ]
                                }
                            },
                        ]
                    }
                },
                "_source": [
                    "@timestamp", "log", "message",
                    "kubernetes.pod_name", "kubernetes.namespace_name",
                ],
            },
        )
        logs = []
        for h in resp["hits"]["hits"]:
            src = h["_source"]
            ts = src.get("@timestamp", "")
            pod = src.get("kubernetes", {}).get("pod_name", "unknown")
            ns = src.get("kubernetes", {}).get("namespace_name", "unknown")
            msg = src.get("message") or src.get("log", "")
            logs.append(f"[{ts}] {ns}/{pod}: {str(msg)[:200]}")
        logger.info(f"Fetched {len(logs)} error log samples from ES")
        return logs
    except Exception as e:
        logger.warning(f"ES fetch failed (continuing without logs): {e}")
        return []


async def generate_summary(alerts: list[dict], logs: list[str]) -> str:
    """Claude API でアラートの状況・影響・対処をサマリする"""
    if not ANTHROPIC_API_KEY:
        logger.warning("ANTHROPIC_API_KEY not set — returning raw alert info")
        return _format_fallback(alerts)

    alert_json = json.dumps(
        [
            {
                "alertname": a["labels"].get("alertname"),
                "severity": a["labels"].get("severity"),
                "namespace": a["labels"].get("namespace", ""),
                "node": a["labels"].get("node", ""),
                "summary": a.get("annotations", {}).get("summary", ""),
                "description": a.get("annotations", {}).get("description", ""),
                "startsAt": a.get("startsAt", ""),
            }
            for a in alerts
        ],
        ensure_ascii=False,
        indent=2,
    )
    log_text = "\n".join(logs) if logs else "(直近エラーログなし)"

    prompt = f"""あなたは Kubernetes クラスターの SRE です。
以下のアラートと直近のエラーログを確認し、日本語で簡潔にサマリを作成してください。

## 発火中のアラート
```json
{alert_json}
```

## 直近エラーログサンプル (過去 {LOG_LOOKBACK_MINUTES} 分)
```
{log_text}
```

以下の形式で回答してください（それ以外のテキストは不要）:
**[状況]** 何が起きているか (2〜3文)
**[影響]** 影響範囲・サービス
**[次のアクション]** 確認・対処すべき手順 (箇条書き 3項目以内)"""

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
    message = client.messages.create(
        model=CLAUDE_MODEL,
        max_tokens=512,
        messages=[{"role": "user", "content": prompt}],
    )
    return message.content[0].text


def _format_fallback(alerts: list[dict]) -> str:
    lines = ["[アラートサマリ] ANTHROPIC_API_KEY 未設定のため生データを出力します:"]
    for a in alerts:
        name = a["labels"].get("alertname", "unknown")
        sev = a["labels"].get("severity", "")
        desc = a.get("annotations", {}).get("description", "")
        lines.append(f"- [{sev.upper()}] {name}: {desc}")
    return "\n".join(lines)


async def post_grafana_annotation(summary: str, alerts: list[dict]) -> None:
    """Grafana にアノテーションを追加する"""
    alert_names = ", ".join({a["labels"].get("alertname", "unknown") for a in alerts})
    severities = {a["labels"].get("severity", "") for a in alerts}
    tags = ["alert", "aiops"] + sorted(severities)

    payload = {
        "text": f"🚨 {alert_names}\n\n{summary}",
        "tags": tags,
    }
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(
            f"{GRAFANA_URL}/api/annotations",
            json=payload,
            auth=(GRAFANA_USER, GRAFANA_PASSWORD),
        )
        resp.raise_for_status()
        logger.info(f"Grafana annotation created: id={resp.json().get('id')}")


async def post_slack(summary: str, alerts: list[dict]) -> None:
    """Slack に通知する"""
    alert_names = ", ".join({a["labels"].get("alertname", "unknown") for a in alerts})
    severities = {a["labels"].get("severity", "") for a in alerts}
    emoji = "🔴" if "critical" in severities else "🟡"
    color = "#FF0000" if "critical" in severities else "#FFA500"

    payload = {
        "text": f"{emoji} *[{', '.join(sorted(severities)).upper()}] {alert_names}*",
        "attachments": [
            {
                "color": color,
                "text": summary,
                "footer": "AIOps alert-summarizer",
                "ts": int(datetime.now(timezone.utc).timestamp()),
            }
        ],
    }
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(SLACK_WEBHOOK_URL, json=payload)
        resp.raise_for_status()
        logger.info("Slack notification sent")
