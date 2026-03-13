#!/usr/bin/env python3
"""
03_monitor_cdc.py — DMS CDC 실시간 모니터링

CloudWatch에서 DMS 메트릭을 수집하여 콘솔에 실시간 표시한다.
CDC lag, 처리 대기 수, CPU, 메모리 등 핵심 지표를 추적한다.
"""

import os
import sys
import time
from datetime import datetime, timedelta, timezone

try:
    import boto3
except ImportError:
    print("boto3가 필요합니다: pip install boto3")
    sys.exit(1)

# ─── 설정 ───
TASK_ID = os.environ.get("DMS_TASK_ID", "doktori-chat-migration")
REPLICATION_INSTANCE_ID = os.environ.get("DMS_INSTANCE_ID", "doktori-dms-repl")
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", 30))  # 초

# 임계값
THRESHOLDS = {
    "CDCLatencySource": {"warn": 30, "crit": 60},
    "CDCLatencyTarget": {"warn": 60, "crit": 300},
    "CDCIncomingChanges": {"warn": 5000, "crit": 10000},
    "CPUUtilization": {"warn": 80, "crit": 90},
    "FreeableMemory_MB": {"warn": 512, "crit": 256},  # 낮을수록 위험
}

# 색상
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"
NC = "\033[0m"


def get_dms_client():
    return boto3.client("dms", region_name=REGION)


def get_cw_client():
    return boto3.client("cloudwatch", region_name=REGION)


def get_task_arn(dms_client: object) -> str:
    """DMS Task ID로 ARN을 조회한다."""
    resp = dms_client.describe_replication_tasks(
        Filters=[{"Name": "replication-task-id", "Values": [TASK_ID]}]
    )
    tasks = resp.get("ReplicationTasks", [])
    if not tasks:
        print(f"{RED}[ERROR]{NC} Task '{TASK_ID}'을 찾을 수 없습니다.")
        sys.exit(1)
    return tasks[0]["ReplicationTaskArn"]


def get_task_status(dms_client: object) -> dict:
    """DMS Task 상태 정보를 조회한다."""
    resp = dms_client.describe_replication_tasks(
        Filters=[{"Name": "replication-task-id", "Values": [TASK_ID]}]
    )
    task = resp["ReplicationTasks"][0]
    return {
        "status": task.get("Status", "unknown"),
        "stop_reason": task.get("StopReason", ""),
        "cdc_start_position": task.get("CdcStartPosition", ""),
        "cdc_stop_position": task.get("CdcStopPosition", ""),
        "percent_complete": task.get("ReplicationTaskStats", {}).get(
            "FullLoadProgressPercent", 0
        ),
        "tables_loaded": task.get("ReplicationTaskStats", {}).get("TablesLoaded", 0),
        "tables_loading": task.get("ReplicationTaskStats", {}).get("TablesLoading", 0),
        "tables_errored": task.get("ReplicationTaskStats", {}).get("TablesErrored", 0),
    }


def get_metric(cw_client, metric_name: str, dimensions: list, period: int = 60) -> float:
    """CloudWatch에서 단일 메트릭의 최신 값을 조회한다."""
    now = datetime.now(timezone.utc)
    resp = cw_client.get_metric_statistics(
        Namespace="AWS/DMS",
        MetricName=metric_name,
        Dimensions=dimensions,
        StartTime=now - timedelta(minutes=5),
        EndTime=now,
        Period=period,
        Statistics=["Average"],
    )
    datapoints = resp.get("Datapoints", [])
    if not datapoints:
        return -1  # 데이터 없음
    latest = max(datapoints, key=lambda d: d["Timestamp"])
    return latest["Average"]


def colorize_metric(name: str, value: float) -> str:
    """메트릭 값에 따라 색상을 적용한다."""
    if value < 0:
        return f"{CYAN}N/A{NC}"

    threshold = THRESHOLDS.get(name)
    if not threshold:
        return f"{value:.1f}"

    # FreeableMemory는 낮을수록 위험
    if "Memory" in name:
        if value <= threshold["crit"]:
            return f"{RED}{BOLD}{value:.0f}{NC}"
        elif value <= threshold["warn"]:
            return f"{YELLOW}{value:.0f}{NC}"
        else:
            return f"{GREEN}{value:.0f}{NC}"
    else:
        if value >= threshold["crit"]:
            return f"{RED}{BOLD}{value:.1f}{NC}"
        elif value >= threshold["warn"]:
            return f"{YELLOW}{value:.1f}{NC}"
        else:
            return f"{GREEN}{value:.1f}{NC}"


def get_table_validation_status(dms_client, task_arn: str) -> dict:
    """테이블별 Validation 상태를 조회한다."""
    resp = dms_client.describe_table_statistics(
        ReplicationTaskArn=task_arn, MaxRecords=100
    )
    result = {}
    for stat in resp.get("TableStatistics", []):
        table_name = stat.get("TableName", "unknown")
        result[table_name] = {
            "inserts": stat.get("Inserts", 0),
            "deletes": stat.get("Deletes", 0),
            "updates": stat.get("Updates", 0),
            "full_load_rows": stat.get("FullLoadRows", 0),
            "validation_state": stat.get("ValidationState", "Not enabled"),
            "validation_pending": stat.get("ValidationPendingRecords", 0),
            "validation_failed": stat.get("ValidationFailedRecords", 0),
        }
    return result


def display_header():
    print(f"\n{BOLD}{'=' * 80}{NC}")
    print(f"{BOLD} DMS CDC 실시간 모니터링 — Task: {TASK_ID}{NC}")
    print(f"{BOLD}{'=' * 80}{NC}")
    print(f" Ctrl+C로 종료 | 갱신 주기: {POLL_INTERVAL}초")
    print(f" 임계값: {YELLOW}WARN{NC} / {RED}CRIT{NC}")
    print()


def display_status(task_status: dict, metrics: dict, table_stats: dict):
    """모니터링 정보를 콘솔에 출력한다."""
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # 상태바 색상
    status = task_status["status"]
    if status == "running":
        status_color = GREEN
    elif status in ("stopped", "failed"):
        status_color = RED
    else:
        status_color = YELLOW

    print(f"\033[2J\033[H")  # 화면 클리어
    display_header()

    # Task 상태
    print(f" {BOLD}Task 상태{NC}")
    print(f"   상태: {status_color}{status}{NC}")
    if task_status["stop_reason"]:
        print(f"   중지 사유: {RED}{task_status['stop_reason']}{NC}")
    print(
        f"   테이블: 로드 완료={task_status['tables_loaded']},"
        f" 로딩 중={task_status['tables_loading']},"
        f" 에러={task_status['tables_errored']}"
    )
    print()

    # CDC 메트릭
    print(f" {BOLD}CDC 메트릭{NC}")
    print(
        f"   CDCLatencySource  : {colorize_metric('CDCLatencySource', metrics['CDCLatencySource'])}s"
        f"  (warn>{THRESHOLDS['CDCLatencySource']['warn']}s,"
        f" crit>{THRESHOLDS['CDCLatencySource']['crit']}s)"
    )
    print(
        f"   CDCLatencyTarget  : {colorize_metric('CDCLatencyTarget', metrics['CDCLatencyTarget'])}s"
        f"  (warn>{THRESHOLDS['CDCLatencyTarget']['warn']}s,"
        f" crit>{THRESHOLDS['CDCLatencyTarget']['crit']}s)"
    )
    print(
        f"   CDCIncomingChanges: {colorize_metric('CDCIncomingChanges', metrics['CDCIncomingChanges'])}"
        f"  (warn>{THRESHOLDS['CDCIncomingChanges']['warn']},"
        f" crit>{THRESHOLDS['CDCIncomingChanges']['crit']})"
    )
    print()

    # 인스턴스 리소스
    print(f" {BOLD}Replication Instance 리소스{NC}")
    print(
        f"   CPU             : {colorize_metric('CPUUtilization', metrics['CPUUtilization'])}%"
        f"  (warn>{THRESHOLDS['CPUUtilization']['warn']}%,"
        f" crit>{THRESHOLDS['CPUUtilization']['crit']}%)"
    )
    mem_mb = metrics["FreeableMemory"] / (1024 * 1024) if metrics["FreeableMemory"] > 0 else -1
    print(
        f"   FreeableMemory  : {colorize_metric('FreeableMemory_MB', mem_mb)} MB"
        f"  (warn<{THRESHOLDS['FreeableMemory_MB']['warn']}MB,"
        f" crit<{THRESHOLDS['FreeableMemory_MB']['crit']}MB)"
    )
    print()

    # 테이블별 상태
    if table_stats:
        print(f" {BOLD}테이블별 CDC 통계{NC}")
        print(f"   {'테이블':<30} {'INSERT':>8} {'UPDATE':>8} {'DELETE':>8} {'Validation':<15}")
        print(f"   {'-' * 75}")
        for table, stat in sorted(table_stats.items()):
            v_state = stat["validation_state"]
            if v_state == "Validated":
                v_color = GREEN
            elif "Mismatched" in v_state:
                v_color = RED
            else:
                v_color = YELLOW
            print(
                f"   {table:<30}"
                f" {stat['inserts']:>8}"
                f" {stat['updates']:>8}"
                f" {stat['deletes']:>8}"
                f" {v_color}{v_state:<15}{NC}"
            )
        print()

    print(f" 마지막 갱신: {now}")


def main():
    dms_client = get_dms_client()
    cw_client = get_cw_client()

    task_arn = get_task_arn(dms_client)

    # 메트릭 차원 설정
    task_dims = [{"Name": "ReplicationTaskIdentifier", "Value": TASK_ID}]
    instance_dims = [
        {"Name": "ReplicationInstanceIdentifier", "Value": REPLICATION_INSTANCE_ID}
    ]

    print("DMS CDC 모니터링을 시작합니다...")

    try:
        while True:
            # 데이터 수집
            task_status = get_task_status(dms_client)
            table_stats = get_table_validation_status(dms_client, task_arn)

            metrics = {
                "CDCLatencySource": get_metric(cw_client, "CDCLatencySource", task_dims),
                "CDCLatencyTarget": get_metric(cw_client, "CDCLatencyTarget", task_dims),
                "CDCIncomingChanges": get_metric(cw_client, "CDCIncomingChanges", task_dims),
                "CPUUtilization": get_metric(cw_client, "CPUUtilization", instance_dims),
                "FreeableMemory": get_metric(cw_client, "FreeableMemory", instance_dims),
            }

            display_status(task_status, metrics, table_stats)

            time.sleep(POLL_INTERVAL)

    except KeyboardInterrupt:
        print(f"\n{YELLOW}모니터링을 종료합니다.{NC}")
        sys.exit(0)


if __name__ == "__main__":
    main()
