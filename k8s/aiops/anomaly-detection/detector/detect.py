#!/usr/bin/env python3
"""
Elasticsearch ログ異常検知スクリプト

処理フロー:
  1. ES から過去 LOOKBACK_HOURS 時間のログ件数を WINDOW_MINUTES 間隔で集計
  2. ADTK (InterQuartileRangeAD) で総ログ量の異常を検知
  3. エラーログの急増 (LevelShiftAD) を検知
  4. Namespace / Pod 別のエラー内訳を集計
  5. 異常検知時はサンプルエラーメッセージをログ出力
  6. 結果を Prometheus Pushgateway に push
"""

import logging
import os
import sys
from datetime import datetime, timedelta, timezone

import numpy as np
import pandas as pd
from adtk.data import validate_series
from adtk.detector import InterQuartileRangeAD, LevelShiftAD
from elasticsearch import Elasticsearch
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)

# -------------------------------------------------------------------
# 設定 (環境変数で上書き可能)
# -------------------------------------------------------------------
ES_URL = os.getenv("ES_URL", "http://elasticsearch-master.logging.svc.cluster.local:9200")
PUSHGATEWAY_URL = os.getenv(
    "PUSHGATEWAY_URL", "http://prometheus-pushgateway.monitoring.svc.cluster.local:9091"
)
LOOKBACK_HOURS = int(os.getenv("LOOKBACK_HOURS", "6"))
WINDOW_MINUTES = int(os.getenv("WINDOW_MINUTES", "5"))
ES_INDEX_PATTERN = os.getenv("ES_INDEX_PATTERN", "fluent-bit-*")
TOP_PODS = int(os.getenv("TOP_PODS", "5"))          # Pod 別内訳の上位件数
SAMPLE_ERRORS = int(os.getenv("SAMPLE_ERRORS", "5")) # 異常検知時のサンプル件数

# 異常検知に必要な最低バケット数 (6h / 5min = 72 バケット)
MIN_BUCKETS = 12

# エラーログのフィルタ条件 (再利用)
ERROR_FILTER = {
    "bool": {
        "should": [
            {"terms": {"level.keyword": ["error", "ERROR", "ERR"]}},
            {"terms": {"log_level.keyword": ["error", "ERROR"]}},
            {"term": {"stream.keyword": "stderr"}},
        ],
        "minimum_should_match": 1,
    }
}


# -------------------------------------------------------------------
# Elasticsearch クエリ — 時系列集計
# -------------------------------------------------------------------
def query_log_counts(es: Elasticsearch, lookback_hours: int, interval_min: int) -> dict:
    """総ログ件数とエラーログ件数を時系列で取得する。"""
    now = datetime.now(timezone.utc)
    since = now - timedelta(hours=lookback_hours)
    time_range = {"range": {"@timestamp": {"gte": since.isoformat(), "lte": now.isoformat()}}}
    interval = f"{interval_min}m"

    def _agg(extra_filter=None):
        query = {"bool": {"must": [time_range]}}
        if extra_filter:
            query["bool"]["must"].append(extra_filter)
        return es.search(
            index=ES_INDEX_PATTERN,
            body={
                "size": 0,
                "query": query,
                "aggs": {
                    "over_time": {
                        "date_histogram": {
                            "field": "@timestamp",
                            "fixed_interval": interval,
                            "min_doc_count": 0,
                            "extended_bounds": {
                                "min": since.isoformat(),
                                "max": now.isoformat(),
                            },
                        }
                    }
                },
            },
        )

    total_resp = _agg()
    error_resp = _agg(ERROR_FILTER)

    return {
        "total": total_resp["aggregations"]["over_time"]["buckets"],
        "errors": error_resp["aggregations"]["over_time"]["buckets"],
    }


# -------------------------------------------------------------------
# Elasticsearch クエリ — Namespace / Pod 別内訳
# -------------------------------------------------------------------
def query_error_counts_by_namespace(es: Elasticsearch, lookback_hours: int) -> list[dict]:
    """Namespace ごとのエラーログ件数を返す。"""
    now = datetime.now(timezone.utc)
    since = now - timedelta(hours=lookback_hours)
    resp = es.search(
        index=ES_INDEX_PATTERN,
        body={
            "size": 0,
            "query": {
                "bool": {
                    "must": [
                        {"range": {"@timestamp": {"gte": since.isoformat()}}},
                        ERROR_FILTER,
                    ]
                }
            },
            "aggs": {
                "by_namespace": {
                    "terms": {
                        "field": "kubernetes.namespace_name.keyword",
                        "size": 20,
                        "missing": "__unknown__",
                    }
                }
            },
        },
    )
    return resp["aggregations"]["by_namespace"]["buckets"]


def query_top_error_pods(es: Elasticsearch, lookback_hours: int, top_n: int) -> list[dict]:
    """エラーログが多い上位 Pod を返す。"""
    now = datetime.now(timezone.utc)
    since = now - timedelta(hours=lookback_hours)
    resp = es.search(
        index=ES_INDEX_PATTERN,
        body={
            "size": 0,
            "query": {
                "bool": {
                    "must": [
                        {"range": {"@timestamp": {"gte": since.isoformat()}}},
                        ERROR_FILTER,
                    ]
                }
            },
            "aggs": {
                "by_namespace": {
                    "terms": {
                        "field": "kubernetes.namespace_name.keyword",
                        "size": 20,
                        "missing": "__unknown__",
                    },
                    "aggs": {
                        "by_pod": {
                            "terms": {
                                "field": "kubernetes.pod_name.keyword",
                                "size": top_n,
                                "missing": "__unknown__",
                            }
                        }
                    },
                }
            },
        },
    )
    results = []
    for ns_bucket in resp["aggregations"]["by_namespace"]["buckets"]:
        namespace = ns_bucket["key"]
        for pod_bucket in ns_bucket["by_pod"]["buckets"]:
            results.append({
                "namespace": namespace,
                "pod": pod_bucket["key"],
                "count": pod_bucket["doc_count"],
            })
    results.sort(key=lambda x: x["count"], reverse=True)
    return results[:top_n]


def query_sample_error_messages(es: Elasticsearch, n: int) -> list[dict]:
    """直近のエラーメッセージをサンプリングする (異常時のログ出力用)。"""
    now = datetime.now(timezone.utc)
    since = now - timedelta(minutes=30)
    resp = es.search(
        index=ES_INDEX_PATTERN,
        body={
            "size": n,
            "sort": [{"@timestamp": "desc"}],
            "query": {
                "bool": {
                    "must": [
                        {"range": {"@timestamp": {"gte": since.isoformat()}}},
                        ERROR_FILTER,
                    ]
                }
            },
            "_source": [
                "@timestamp",
                "message",
                "log",
                "kubernetes.namespace_name",
                "kubernetes.pod_name",
            ],
        },
    )
    results = []
    for hit in resp["hits"]["hits"]:
        src = hit["_source"]
        results.append({
            "ts": src.get("@timestamp", ""),
            "namespace": src.get("kubernetes", {}).get("namespace_name", "?"),
            "pod": src.get("kubernetes", {}).get("pod_name", "?"),
            "message": (src.get("message") or src.get("log", ""))[:200],
        })
    return results


# -------------------------------------------------------------------
# 異常検知
# -------------------------------------------------------------------
def _to_series(buckets: list) -> pd.Series:
    """ES バケットリストを pandas Series に変換する。"""
    if not buckets:
        return pd.Series(dtype=float)
    timestamps = pd.to_datetime([b["key_as_string"] for b in buckets], utc=True)
    counts = [float(b["doc_count"]) for b in buckets]
    return pd.Series(counts, index=timestamps)


def detect_iqr_anomaly(buckets: list) -> tuple[bool, float]:
    """
    InterQuartileRangeAD で直近バケットが外れ値かどうかを判定する。
    Returns: (is_anomaly, latest_value)
    """
    series = _to_series(buckets)
    if len(series) < MIN_BUCKETS:
        logger.warning(f"Not enough data ({len(series)} buckets < {MIN_BUCKETS}), skipping IQR detection")
        return False, float(series.iloc[-1]) if len(series) > 0 else 0.0

    try:
        series = validate_series(series)
        detector = InterQuartileRangeAD(c=3.0)
        anomalies = detector.fit_detect(series)
        is_anomaly = bool(anomalies.iloc[-1])
        return is_anomaly, float(series.iloc[-1])
    except Exception as exc:
        logger.warning(f"IQR detection failed: {exc}")
        return False, float(series.iloc[-1])


def detect_level_shift(buckets: list) -> bool:
    """
    LevelShiftAD でレベルシフト (急増・急減) を検知する。
    Returns: is_anomaly
    """
    series = _to_series(buckets)
    if len(series) < MIN_BUCKETS * 2:
        return False

    try:
        series = validate_series(series)
        detector = LevelShiftAD(c=6.0, side="positive", window=6)
        anomalies = detector.fit_detect(series)
        return bool(anomalies.iloc[-1])
    except Exception as exc:
        logger.warning(f"LevelShift detection failed: {exc}")
        return False


# -------------------------------------------------------------------
# メイン
# -------------------------------------------------------------------
def main() -> None:
    logger.info(f"Connecting to ES: {ES_URL}")
    es = Elasticsearch(ES_URL, request_timeout=30)

    health = es.cluster.health()
    logger.info(f"ES cluster status: {health['status']}")

    # ── 時系列集計 & 異常検知 ───────────────────────────────────────
    logger.info(f"Querying index={ES_INDEX_PATTERN} lookback={LOOKBACK_HOURS}h interval={WINDOW_MINUTES}m")
    data = query_log_counts(es, LOOKBACK_HOURS, WINDOW_MINUTES)

    total_buckets = data["total"]
    error_buckets = data["errors"]
    logger.info(f"Fetched {len(total_buckets)} total buckets, {len(error_buckets)} error buckets")

    total_anomaly, total_latest = detect_iqr_anomaly(total_buckets)
    error_anomaly, error_latest = detect_iqr_anomaly(error_buckets)
    error_shift = detect_level_shift(error_buckets)
    error_rate = error_latest / total_latest if total_latest > 0 else 0.0

    logger.info(
        f"total={total_latest:.0f} anomaly={total_anomaly} | "
        f"errors={error_latest:.0f} anomaly={error_anomaly} shift={error_shift} | "
        f"error_rate={error_rate:.4f}"
    )

    # ── Namespace / Pod 別内訳 ────────────────────────────────────
    ns_counts = query_error_counts_by_namespace(es, LOOKBACK_HOURS)
    top_pods = query_top_error_pods(es, LOOKBACK_HOURS, TOP_PODS)

    logger.info("=== Error count by namespace (last %dh) ===", LOOKBACK_HOURS)
    for b in ns_counts:
        logger.info(f"  {b['key']:40s} {b['doc_count']:6d} errors")

    logger.info("=== Top %d error pods ===", TOP_PODS)
    for p in top_pods:
        logger.info(f"  {p['namespace']:20s} / {p['pod']:50s} {p['count']:6d} errors")

    # ── 異常検知時: サンプルエラーメッセージ出力 ─────────────────
    any_anomaly = total_anomaly or error_anomaly or error_shift
    if any_anomaly:
        logger.warning("!!! ANOMALY DETECTED — sampling recent error messages !!!")
        samples = query_sample_error_messages(es, SAMPLE_ERRORS)
        for i, s in enumerate(samples, 1):
            logger.warning(
                f"  [{i}] {s['ts']} {s['namespace']}/{s['pod']}: {s['message']}"
            )

    # ── Pushgateway へ push ────────────────────────────────────────
    registry = CollectorRegistry()

    # 集計メトリクス
    Gauge("log_total_count", "Total log count in latest window", registry=registry).set(total_latest)
    Gauge("log_error_count", "Error log count in latest window", registry=registry).set(error_latest)
    Gauge("log_error_rate", "Error log rate (errors / total)", registry=registry).set(error_rate)
    Gauge("log_anomaly_total_detected", "1 if total log volume anomaly detected (IQR)", registry=registry).set(1.0 if total_anomaly else 0.0)
    Gauge("log_anomaly_error_detected", "1 if error log count anomaly detected (IQR)", registry=registry).set(1.0 if error_anomaly else 0.0)
    Gauge("log_anomaly_error_shift_detected", "1 if sudden error log level-shift detected", registry=registry).set(1.0 if error_shift else 0.0)

    # Namespace 別エラー件数
    ns_gauge = Gauge(
        "log_error_count_by_namespace",
        "Error log count per namespace (last LOOKBACK_HOURS)",
        ["namespace"],
        registry=registry,
    )
    for b in ns_counts:
        ns_gauge.labels(namespace=b["key"]).set(b["doc_count"])

    # Pod 別エラー件数 (上位のみ)
    pod_gauge = Gauge(
        "log_error_count_by_pod",
        "Error log count per pod (top pods only)",
        ["namespace", "pod"],
        registry=registry,
    )
    for p in top_pods:
        pod_gauge.labels(namespace=p["namespace"], pod=p["pod"]).set(p["count"])

    push_to_gateway(PUSHGATEWAY_URL, job="log-anomaly-detector", registry=registry)
    logger.info(f"Metrics pushed to {PUSHGATEWAY_URL}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        logger.error(f"Fatal: {exc}", exc_info=True)
        sys.exit(1)
