#!/usr/bin/env python3
"""
Elasticsearch ログ異常検知スクリプト

処理フロー:
  1. ES から過去 LOOKBACK_HOURS 時間のログ件数を WINDOW_MINUTES 間隔で集計
  2. ADTK (InterQuartileRangeAD) で総ログ量の異常を検知
  3. エラーログの急増 (LevelShiftAD) を検知
  4. 結果を Prometheus Pushgateway に push
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

# 異常検知に必要な最低バケット数 (6h / 5min = 72 バケット)
MIN_BUCKETS = 12


# -------------------------------------------------------------------
# Elasticsearch クエリ
# -------------------------------------------------------------------
def query_log_counts(es: Elasticsearch, index: str, lookback_hours: int, interval_min: int) -> dict:
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
            index=index,
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

    # エラーログ: level=error OR stream=stderr で近似
    error_filter = {
        "bool": {
            "should": [
                {"terms": {"level.keyword": ["error", "ERROR", "ERR"]}},
                {"terms": {"log_level.keyword": ["error", "ERROR"]}},
                {"term": {"stream.keyword": "stderr"}},
            ],
            "minimum_should_match": 1,
        }
    }

    total_resp = _agg()
    error_resp = _agg(error_filter)

    return {
        "total": total_resp["aggregations"]["over_time"]["buckets"],
        "errors": error_resp["aggregations"]["over_time"]["buckets"],
    }


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

    # 疎通確認
    health = es.cluster.health()
    logger.info(f"ES cluster status: {health['status']}")

    # ログ件数取得
    logger.info(
        f"Querying index={ES_INDEX_PATTERN} lookback={LOOKBACK_HOURS}h interval={WINDOW_MINUTES}m"
    )
    data = query_log_counts(es, ES_INDEX_PATTERN, LOOKBACK_HOURS, WINDOW_MINUTES)

    total_buckets = data["total"]
    error_buckets = data["errors"]
    logger.info(f"Fetched {len(total_buckets)} total buckets, {len(error_buckets)} error buckets")

    # 異常検知
    total_anomaly, total_latest = detect_iqr_anomaly(total_buckets)
    error_anomaly, error_latest = detect_iqr_anomaly(error_buckets)
    error_shift = detect_level_shift(error_buckets)

    error_rate = error_latest / total_latest if total_latest > 0 else 0.0

    logger.info(
        f"total_latest={total_latest:.0f} anomaly={total_anomaly} | "
        f"error_latest={error_latest:.0f} anomaly={error_anomaly} shift={error_shift} | "
        f"error_rate={error_rate:.4f}"
    )

    # Pushgateway へ push
    registry = CollectorRegistry()

    Gauge("log_total_count", "Total log count in latest window", registry=registry).set(total_latest)
    Gauge("log_error_count", "Error log count in latest window", registry=registry).set(error_latest)
    Gauge("log_error_rate", "Error log rate (errors / total)", registry=registry).set(error_rate)
    Gauge(
        "log_anomaly_total_detected",
        "1 if total log volume anomaly detected (IQR)",
        registry=registry,
    ).set(1.0 if total_anomaly else 0.0)
    Gauge(
        "log_anomaly_error_detected",
        "1 if error log count anomaly detected (IQR)",
        registry=registry,
    ).set(1.0 if error_anomaly else 0.0)
    Gauge(
        "log_anomaly_error_shift_detected",
        "1 if sudden error log level-shift detected",
        registry=registry,
    ).set(1.0 if error_shift else 0.0)

    push_to_gateway(PUSHGATEWAY_URL, job="log-anomaly-detector", registry=registry)
    logger.info(f"Metrics pushed to {PUSHGATEWAY_URL}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        logger.error(f"Fatal: {exc}", exc_info=True)
        sys.exit(1)
