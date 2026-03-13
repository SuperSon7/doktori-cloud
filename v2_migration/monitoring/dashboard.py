#!/usr/bin/env python3
"""
dashboard.py — DMS 마이그레이션 터미널 실시간 대시보드

Full Load 진행률, CDC lag, 테이블별 동기화 상태를
터미널에서 실시간으로 시각화한다. (progress bar, 상태 표시 등)
"""

import os
import sys
import time
import shutil
from datetime import datetime, timedelta, timezone

try:
    import boto3
except ImportError:
    print("boto3가 필요합니다: pip install boto3")
    sys.exit(1)

# ─── 설정 ───
DMS_TASK_ID = os.environ.get("DMS_TASK_ID", "doktori-chat-migration")
DMS_INSTANCE_ID = os.environ.get("DMS_INSTANCE_ID", "doktori-dms-repl")
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", 10))

# 색상
R = "\033[31m"
G = "\033[32m"
Y = "\033[33m"
B = "\033[34m"
M = "\033[35m"
C = "\033[36m"
W = "\033[37m"
BOLD = "\033[1m"
DIM = "\033[2m"
NC = "\033[0m"

# 블록 문자 (progress bar용)
FULL_BLOCK = "█"
LIGHT_BLOCK = "░"


def get_clients():
    return (
        boto3.client("dms", region_name=REGION),
        boto3.client("cloudwatch", region_name=REGION),
    )


def get_task_info(dms):
    resp = dms.describe_replication_tasks(
        Filters=[{"Name": "replication-task-id", "Values": [DMS_TASK_ID]}]
    )
    tasks = resp.get("ReplicationTasks", [])
    if not tasks:
        return None
    return tasks[0]


def get_table_stats(dms, task_arn: str) -> list:
    resp = dms.describe_table_statistics(
        ReplicationTaskArn=task_arn, MaxRecords=100
    )
    return resp.get("TableStatistics", [])


def get_metric_value(cw, metric_name: str, dim_name: str, dim_value: str) -> float:
    now = datetime.now(timezone.utc)
    resp = cw.get_metric_statistics(
        Namespace="AWS/DMS",
        MetricName=metric_name,
        Dimensions=[{"Name": dim_name, "Value": dim_value}],
        StartTime=now - timedelta(minutes=5),
        EndTime=now,
        Period=60,
        Statistics=["Average"],
    )
    dps = resp.get("Datapoints", [])
    if not dps:
        return -1
    return max(dps, key=lambda d: d["Timestamp"])["Average"]


def progress_bar(percent: float, width: int = 40) -> str:
    """터미널 진행률 바를 생성한다."""
    filled = int(width * percent / 100)
    remaining = width - filled

    if percent >= 100:
        color = G
    elif percent >= 50:
        color = C
    else:
        color = Y

    bar = f"{color}{FULL_BLOCK * filled}{DIM}{LIGHT_BLOCK * remaining}{NC}"
    return f" {bar} {BOLD}{percent:5.1f}%{NC}"


def lag_bar(lag_seconds: float, max_val: float = 300, width: int = 30) -> str:
    """CDC lag 시각화 바."""
    if lag_seconds < 0:
        return f" {DIM}{'─' * width} N/A{NC}"

    filled = min(int(width * lag_seconds / max_val), width)

    if lag_seconds < 5:
        color = G
    elif lag_seconds < 60:
        color = Y
    else:
        color = R

    bar = f"{color}{'▮' * filled}{DIM}{'─' * (width - filled)}{NC}"
    return f" {bar} {color}{lag_seconds:.1f}s{NC}"


def resource_bar(value: float, max_val: float = 100, width: int = 20,
                 warn: float = 80, crit: float = 90, invert: bool = False) -> str:
    """CPU/메모리 사용률 바."""
    if value < 0:
        return f" {DIM}{'─' * width} N/A{NC}"

    filled = min(int(width * value / max_val), width)

    if invert:  # 메모리: 낮을수록 위험
        if value <= crit:
            color = R
        elif value <= warn:
            color = Y
        else:
            color = G
    else:
        if value >= crit:
            color = R
        elif value >= warn:
            color = Y
        else:
            color = G

    bar = f"{color}{'▮' * filled}{DIM}{'─' * (width - filled)}{NC}"
    return f" {bar} {color}{value:.0f}{NC}"


def status_icon(status: str) -> str:
    """상태에 따른 아이콘."""
    icons = {
        "running": f"{G}● RUN{NC}",
        "stopped": f"{R}■ STOP{NC}",
        "starting": f"{Y}◐ START{NC}",
        "stopping": f"{Y}◑ STOP{NC}",
        "creating": f"{C}◌ CREATE{NC}",
        "deleting": f"{R}✕ DEL{NC}",
        "failed": f"{R}✕ FAIL{NC}",
        "ready": f"{C}○ READY{NC}",
    }
    return icons.get(status, f"{W}? {status}{NC}")


def validation_icon(state: str) -> str:
    icons = {
        "Validated": f"{G}✓{NC}",
        "Pending records": f"{Y}…{NC}",
        "Mismatched records": f"{R}✕{NC}",
        "Not enabled": f"{DIM}─{NC}",
        "No primary key": f"{Y}!{NC}",
    }
    return icons.get(state, f"{W}?{NC}")


def render(dms, cw, task_info, start_time: datetime):
    """전체 대시보드를 렌더링한다."""
    term_width = shutil.get_terminal_size().columns
    now_str = datetime.now().strftime("%H:%M:%S")
    elapsed = datetime.now() - start_time
    elapsed_str = str(elapsed).split(".")[0]

    task_arn = task_info["ReplicationTaskArn"]
    status = task_info.get("Status", "unknown")
    stats = task_info.get("ReplicationTaskStats", {})

    tables_loaded = stats.get("TablesLoaded", 0)
    tables_loading = stats.get("TablesLoading", 0)
    tables_errored = stats.get("TablesErrored", 0)
    total_tables = tables_loaded + tables_loading + stats.get("TablesQueued", 0)
    fl_percent = stats.get("FullLoadProgressPercent", 0)

    # 테이블별 통계
    table_stats = get_table_stats(dms, task_arn)

    # CloudWatch 메트릭
    lag_src = get_metric_value(cw, "CDCLatencySource", "ReplicationTaskIdentifier", DMS_TASK_ID)
    lag_tgt = get_metric_value(cw, "CDCLatencyTarget", "ReplicationTaskIdentifier", DMS_TASK_ID)
    cpu = get_metric_value(cw, "CPUUtilization", "ReplicationInstanceIdentifier", DMS_INSTANCE_ID)
    mem = get_metric_value(cw, "FreeableMemory", "ReplicationInstanceIdentifier", DMS_INSTANCE_ID)
    mem_mb = mem / (1024 * 1024) if mem > 0 else -1

    # ─── 화면 클리어 및 렌더링 ───
    print("\033[2J\033[H", end="")

    # 헤더
    header = f" DMS Migration Dashboard"
    print(f"{BOLD}{'═' * term_width}{NC}")
    print(f"{BOLD}{header}{NC}")
    print(f" Task: {C}{DMS_TASK_ID}{NC}  |  Instance: {C}{DMS_INSTANCE_ID}{NC}")
    print(f" Status: {status_icon(status)}  |  Time: {now_str}  |  Elapsed: {elapsed_str}")
    print(f"{BOLD}{'═' * term_width}{NC}")

    # ─── Full Load 진행률 ───
    print()
    print(f" {BOLD}Full Load{NC}")
    print(f"  Progress:{progress_bar(fl_percent)}")
    print(f"  Tables: {G}{tables_loaded}{NC} loaded / {Y}{tables_loading}{NC} loading"
          f" / {R}{tables_errored}{NC} errored / {total_tables} total")

    # ─── CDC Lag ───
    print()
    print(f" {BOLD}CDC Replication Lag{NC}")
    print(f"  Source :{lag_bar(lag_src, max_val=120)}  {DIM}(binlog read){NC}")
    print(f"  Target :{lag_bar(lag_tgt, max_val=600)}  {DIM}(end-to-end){NC}")

    # lag 상태 판정
    if lag_tgt >= 0:
        if lag_tgt < 5:
            print(f"  {G}{BOLD}  CUTOVER READY{NC} {DIM}— lag < 5s{NC}")
        elif lag_tgt < 60:
            print(f"  {Y}  SYNCING{NC} {DIM}— lag {lag_tgt:.0f}s{NC}")
        else:
            print(f"  {R}  LAG HIGH{NC} {DIM}— lag {lag_tgt:.0f}s, 인스턴스 스케일업 검토{NC}")

    # ─── Instance Resources ───
    print()
    print(f" {BOLD}Instance Resources{NC}")
    print(f"  CPU    :{resource_bar(cpu, max_val=100, warn=80, crit=90)}%")
    print(f"  Memory :{resource_bar(mem_mb, max_val=4096, warn=512, crit=256, invert=True)} MB free")

    # ─── 테이블별 상태 ───
    print()
    print(f" {BOLD}Table Sync Status{NC}")

    if table_stats:
        # 헤더
        print(f"  {'Table':<30} {'FullLoad':>10} {'Insert':>8} {'Update':>8}"
              f" {'Delete':>8} {'Valid':>5}")
        print(f"  {'─' * 75}")

        for s in sorted(table_stats, key=lambda x: x.get("TableName", "")):
            name = s.get("TableName", "?")
            fl_rows = s.get("FullLoadRows", 0)
            ins = s.get("Inserts", 0)
            upd = s.get("Updates", 0)
            dlt = s.get("Deletes", 0)
            v_state = s.get("ValidationState", "Not enabled")
            v_icon = validation_icon(v_state)

            # 행 색상: 에러가 있으면 빨간색
            row_color = NC
            if s.get("TableState") == "Table error":
                row_color = R

            print(f"  {row_color}{name:<30} {fl_rows:>10,} {ins:>8,}"
                  f" {upd:>8,} {dlt:>8,}{NC}   {v_icon}")
    else:
        print(f"  {DIM}(테이블 통계 없음){NC}")

    # ─── 하단 ───
    print()
    print(f"{'─' * term_width}")
    print(f" {DIM}Ctrl+C 종료 | 갱신: {POLL_INTERVAL}s | {G}✓{NC}=Validated"
          f" {Y}…{NC}=Pending {R}✕{NC}=Mismatch{NC}")


def main():
    dms, cw = get_clients()
    start_time = datetime.now()

    print("DMS 대시보드를 시작합니다...")

    try:
        while True:
            task_info = get_task_info(dms)
            if task_info is None:
                print(f"\n{R}Task '{DMS_TASK_ID}'을 찾을 수 없습니다.{NC}")
                sys.exit(1)

            render(dms, cw, task_info, start_time)
            time.sleep(POLL_INTERVAL)

    except KeyboardInterrupt:
        print(f"\n{Y}대시보드를 종료합니다.{NC}")
        sys.exit(0)


if __name__ == "__main__":
    main()
