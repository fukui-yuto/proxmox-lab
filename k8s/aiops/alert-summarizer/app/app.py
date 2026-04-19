"""
alert-summarizer: AlertManager webhook → ルールベースサマリ → Grafana Annotation / Slack
"""
import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

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
ES_INDEX_PATTERN = os.getenv("ES_INDEX_PATTERN", "fluent-bit-*")
LOG_LOOKBACK_MINUTES = int(os.getenv("LOG_LOOKBACK_MINUTES", "15"))
MAX_LOG_SAMPLES = int(os.getenv("MAX_LOG_SAMPLES", "20"))

# ─── アラート別の対処テンプレート ─────────────────────────────────────────────
# alertname をキーにして、影響と対処手順を定義する
ALERT_TEMPLATES: dict[str, dict[str, str]] = {
    "DiskSpaceExhaustionIn24h": {
        "impact": "ディスク枯渇によるサービス停止の恐れ",
        "actions": "- `df -h` でディスク使用量を確認\n- 不要ファイル・古いログを削除\n- ディスク拡張を検討",
    },
    "DiskSpaceExhaustionIn4h": {
        "impact": "4時間以内にディスク枯渇 — 即時対応が必要",
        "actions": "- `df -h` で使用量を確認し緊急削除\n- PVC 拡張または retention 短縮\n- 該当ノードのワークロード退避",
    },
    "CPUSpikeHighSustained": {
        "impact": "CPU 過負荷によるレスポンス低下・Pod 退避",
        "actions": "- `kubectl top pods -A` で CPU 消費 Pod を特定\n- 該当 Pod のリソース制限を見直し\n- 不要なワークロードをスケールダウン",
    },
    "MemoryExhaustionIn2h": {
        "impact": "メモリ枯渇による OOM Kill の恐れ",
        "actions": "- `kubectl top nodes` でメモリ使用量を確認\n- メモリリーク Pod を特定しリスタート\n- メモリ limit を見直し",
    },
    "NodeMemoryPressureHigh": {
        "impact": "ノードメモリ圧迫 — OOM Kill が発生する恐れ",
        "actions": "- `kubectl top pods --sort-by=memory` で確認\n- 不要 Pod を退避・削除\n- ノードメモリ増設を検討",
    },
    "PodRestartRateHigh": {
        "impact": "Pod 不安定 — CrashLoopBackOff の前兆",
        "actions": "- `kubectl logs <pod> --previous` で直前のクラッシュログを確認\n- リソース不足・設定ミスを調査\n- 必要に応じて rollout restart",
    },
    "PodRestartRateCritical": {
        "impact": "Pod が頻繁に再起動 — サービス影響あり",
        "actions": "- `kubectl describe pod` でイベントを確認\n- `kubectl logs --previous` でクラッシュ原因を調査\n- 根本原因を修正してデプロイし直す",
    },
    "PodOOMKilled": {
        "impact": "OOM Kill 発生 — メモリ limit 超過",
        "actions": "- 自動修復: メモリ limit を 1.5 倍に増加 (Argo Workflows)\n- メモリリークがないか確認\n- limit を適正値に調整",
    },
    "PodCrashLoopBackOff": {
        "impact": "CrashLoopBackOff — Pod が起動できない",
        "actions": "- 自動分析: ログ収集・エラーパターン検出 (Argo Workflows)\n- `kubectl logs --previous` で原因調査\n- 設定・イメージを修正してデプロイ",
    },
    "LonghornVolumeFaulted": {
        "impact": "ストレージ障害 — Pod の I/O エラーの恐れ",
        "actions": "- 自動修復: VolumeAttachment クリーンアップ + instance-manager 再起動 (Argo Workflows)\n- `kubectl get volumes.longhorn.io -n longhorn-system` で状態確認\n- k8s/longhorn/README.md の復旧手順を参照",
    },
    "LonghornVolumeDegraded": {
        "impact": "レプリカ不足 — 冗長性が低下",
        "actions": "- Longhorn UI でレプリカ再構築の進捗を確認\n- ノード間のネットワーク接続を確認\n- ディスク容量に余裕があるか確認",
    },
    "LonghornNodeStorageLow": {
        "impact": "Longhorn ストレージ容量逼迫",
        "actions": "- 不要なスナップショットを削除\n- 使われていないボリュームを削除\n- ディスク拡張を検討",
    },
    "PrometheusStorageHigh": {
        "impact": "Prometheus ストレージ逼迫 — メトリクスロストの恐れ",
        "actions": "- `retention` 設定を短くする\n- 不要な ServiceMonitor を無効化\n- PVC 拡張を検討",
    },
}


# ─── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(title="alert-summarizer", version="2.0.0")


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
        summary = generate_summary(firing, logs)
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


def generate_summary(alerts: list[dict], logs: list[str]) -> str:
    """ルールベースでアラートの状況・影響・対処をサマリする (AI API 不使用)"""
    sections: list[str] = []

    # --- [状況] ---
    alert_descs = []
    for a in alerts:
        name = a["labels"].get("alertname", "unknown")
        sev = a["labels"].get("severity", "unknown")
        summary = a.get("annotations", {}).get("summary", "")
        ns = a["labels"].get("namespace", "")
        node = a["labels"].get("node", "")
        location = ns or node or ""
        alert_descs.append(f"[{sev.upper()}] {name}" + (f" ({location})" if location else "") + (f": {summary}" if summary else ""))
    sections.append("**[状況]** " + "; ".join(alert_descs))

    # --- [影響] ---
    impacts = set()
    namespaces = set()
    for a in alerts:
        name = a["labels"].get("alertname", "")
        ns = a["labels"].get("namespace", "")
        if ns:
            namespaces.add(ns)
        tmpl = ALERT_TEMPLATES.get(name)
        if tmpl:
            impacts.add(tmpl["impact"])
        else:
            desc = a.get("annotations", {}).get("description", "")
            if desc:
                impacts.add(desc[:100])
    impact_text = "; ".join(impacts) if impacts else "影響範囲を確認中"
    if namespaces:
        impact_text += f" (namespace: {', '.join(sorted(namespaces))})"
    sections.append(f"**[影響]** {impact_text}")

    # --- [次のアクション] ---
    actions = []
    seen_actions = set()
    for a in alerts:
        name = a["labels"].get("alertname", "")
        tmpl = ALERT_TEMPLATES.get(name)
        if tmpl and tmpl["actions"] not in seen_actions:
            actions.append(tmpl["actions"])
            seen_actions.add(tmpl["actions"])
    if not actions:
        actions.append("- `kubectl describe pod` / `kubectl logs` で該当リソースの状態を確認\n- アラートの annotations.description を参照\n- 必要に応じて担当者にエスカレーション")
    sections.append("**[次のアクション]**\n" + "\n".join(actions))

    # --- ログサンプル ---
    if logs:
        log_sample = "\n".join(logs[:5])
        sections.append(f"**[直近エラーログ (過去{LOG_LOOKBACK_MINUTES}分, 上位{min(len(logs), 5)}件)]**\n```\n{log_sample}\n```")

    return "\n\n".join(sections)


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
