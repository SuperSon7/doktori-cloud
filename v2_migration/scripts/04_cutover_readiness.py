#!/usr/bin/env python3
"""
04_cutover_readiness.py — 컷오버 준비 상태 자동 검증

DMS CDC lag, Data Validation 상태, MongoDB 인덱스, 데이터 정합성 등
컷오버 전 체크리스트를 자동으로 검증하고 Go/No-Go 판정을 내린다.
"""

import os
import sys
import json
from datetime import datetime, timedelta, timezone

try:
    import boto3
    import mysql.connector
    from pymongo import MongoClient
except ImportError:
    print("필요한 패키지: pip install boto3 mysql-connector-python pymongo")
    sys.exit(1)

# ─── 설정 ───
DMS_TASK_ID = os.environ.get("DMS_TASK_ID", "doktori-chat-migration")
DMS_INSTANCE_ID = os.environ.get("DMS_INSTANCE_ID", "doktori-dms-repl")
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")

MYSQL_CONFIG = {
    "host": os.environ.get("MYSQL_HOST", "localhost"),
    "port": int(os.environ.get("MYSQL_PORT", 3306)),
    "user": os.environ.get("MYSQL_USER", "root"),
    "password": os.environ.get("MYSQL_PASS", ""),
    "database": os.environ.get("MYSQL_DB", "doktoridb"),
}

MONGO_CONFIG = {
    "host": os.environ.get("MONGO_HOST", "localhost"),
    "port": int(os.environ.get("MONGO_PORT", 27017)),
    "db": os.environ.get("MONGO_DB", "doktori_chat"),
}

# 컷오버 허용 임계값
MAX_CDC_LAG_SECONDS = 5
MAX_VALIDATION_FAILED = 0

# MongoDB에 있어야 할 인덱스 (컬렉션: [인덱스 키 필드 리스트])
REQUIRED_INDEXES = {
    "chatting_rooms": [["status", "id"]],
    "messages": [["room_id", "id"], ["round_id", "id"]],
    "chatting_room_members": [["room_id", "status", "user_id"]],
}

# ─── 색상 ───
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BOLD = "\033[1m"
NC = "\033[0m"

checks_pass = 0
checks_fail = 0
checks_warn = 0


def check_pass(msg):
    global checks_pass
    checks_pass += 1
    print(f"  {GREEN}[PASS]{NC} {msg}")


def check_fail(msg):
    global checks_fail
    checks_fail += 1
    print(f"  {RED}[FAIL]{NC} {msg}")


def check_warn(msg):
    global checks_warn
    checks_warn += 1
    print(f"  {YELLOW}[WARN]{NC} {msg}")


# =============================================================================
# 1. DMS Task 상태 확인
# =============================================================================
def check_dms_task_status():
    print(f"\n{BOLD}1. DMS Task 상태 확인{NC}")
    dms = boto3.client("dms", region_name=REGION)

    resp = dms.describe_replication_tasks(
        Filters=[{"Name": "replication-task-id", "Values": [DMS_TASK_ID]}]
    )
    tasks = resp.get("ReplicationTasks", [])
    if not tasks:
        check_fail(f"Task '{DMS_TASK_ID}' not found")
        return None

    task = tasks[0]
    status = task.get("Status", "unknown")

    if status == "running":
        check_pass(f"Task 상태: {status}")
    else:
        check_fail(f"Task 상태: {status} (running이어야 함)")

    # 에러 테이블 확인
    stats = task.get("ReplicationTaskStats", {})
    errored = stats.get("TablesErrored", 0)
    if errored > 0:
        check_fail(f"에러 테이블: {errored}개")
    else:
        check_pass(f"에러 테이블: 0개")

    return task["ReplicationTaskArn"]


# =============================================================================
# 2. CDC Lag 확인
# =============================================================================
def check_cdc_lag():
    print(f"\n{BOLD}2. CDC Replication Lag 확인{NC}")
    cw = boto3.client("cloudwatch", region_name=REGION)

    now = datetime.now(timezone.utc)

    for metric_name in ["CDCLatencySource", "CDCLatencyTarget"]:
        resp = cw.get_metric_statistics(
            Namespace="AWS/DMS",
            MetricName=metric_name,
            Dimensions=[
                {"Name": "ReplicationTaskIdentifier", "Value": DMS_TASK_ID}
            ],
            StartTime=now - timedelta(minutes=10),
            EndTime=now,
            Period=60,
            Statistics=["Average", "Maximum"],
        )
        datapoints = resp.get("Datapoints", [])
        if not datapoints:
            check_warn(f"{metric_name}: 데이터 없음 (CloudWatch 지연 가능)")
            continue

        latest = max(datapoints, key=lambda d: d["Timestamp"])
        avg = latest["Average"]
        maximum = latest["Maximum"]

        if avg <= MAX_CDC_LAG_SECONDS:
            check_pass(f"{metric_name}: avg={avg:.1f}s, max={maximum:.1f}s (허용: <{MAX_CDC_LAG_SECONDS}s)")
        else:
            check_fail(f"{metric_name}: avg={avg:.1f}s, max={maximum:.1f}s (허용: <{MAX_CDC_LAG_SECONDS}s)")


# =============================================================================
# 3. DMS Data Validation 상태
# =============================================================================
def check_data_validation(task_arn):
    print(f"\n{BOLD}3. DMS Data Validation 상태{NC}")
    if task_arn is None:
        check_fail("Task ARN 없음 — Validation 확인 불가")
        return

    dms = boto3.client("dms", region_name=REGION)
    resp = dms.describe_table_statistics(
        ReplicationTaskArn=task_arn, MaxRecords=100
    )

    for stat in resp.get("TableStatistics", []):
        table = stat.get("TableName", "unknown")
        v_state = stat.get("ValidationState", "Not enabled")
        v_failed = stat.get("ValidationFailedRecords", 0)

        if v_state == "Validated" and v_failed <= MAX_VALIDATION_FAILED:
            check_pass(f"{table}: {v_state} (failed={v_failed})")
        elif v_state == "Not enabled":
            check_warn(f"{table}: Validation 미활성화")
        else:
            check_fail(f"{table}: {v_state} (failed={v_failed})")


# =============================================================================
# 4. Row Count 비교
# =============================================================================
def check_row_counts():
    print(f"\n{BOLD}4. Row Count 비교 (MySQL vs MongoDB){NC}")

    tables = [
        "chatting_rooms", "room_rounds", "chatting_room_members",
        "messages", "quizzes", "quiz_choices",
    ]

    try:
        mysql_conn = mysql.connector.connect(**MYSQL_CONFIG)
        mysql_cursor = mysql_conn.cursor()
    except Exception as e:
        check_fail(f"MySQL 연결 실패: {e}")
        return

    try:
        mongo_client = MongoClient(MONGO_CONFIG["host"], MONGO_CONFIG["port"])
        mongo_db = mongo_client[MONGO_CONFIG["db"]]
    except Exception as e:
        check_fail(f"MongoDB 연결 실패: {e}")
        mysql_cursor.close()
        mysql_conn.close()
        return

    try:
        for table in tables:
            mysql_cursor.execute(f"SELECT COUNT(*) FROM `{table}`")
            mysql_count = mysql_cursor.fetchone()[0]

            mongo_count = mongo_db[table].count_documents({})

            diff = abs(mysql_count - mongo_count)
            # CDC 진행 중이므로 약간의 차이는 허용 (lag 때문)
            if diff == 0:
                check_pass(f"{table}: MySQL={mysql_count}, MongoDB={mongo_count} (일치)")
            elif diff <= 10:
                check_warn(f"{table}: MySQL={mysql_count}, MongoDB={mongo_count} (차이={diff}, CDC lag 허용)")
            else:
                check_fail(f"{table}: MySQL={mysql_count}, MongoDB={mongo_count} (차이={diff})")
    finally:
        mysql_cursor.close()
        mysql_conn.close()


# =============================================================================
# 5. MongoDB 인덱스 확인
# =============================================================================
def check_mongodb_indexes():
    print(f"\n{BOLD}5. MongoDB 인덱스 확인{NC}")

    try:
        mongo_client = MongoClient(MONGO_CONFIG["host"], MONGO_CONFIG["port"])
        mongo_db = mongo_client[MONGO_CONFIG["db"]]
    except Exception as e:
        check_fail(f"MongoDB 연결 실패: {e}")
        return

    for collection, required in REQUIRED_INDEXES.items():
        existing_indexes = mongo_db[collection].index_information()
        existing_keys = []
        for idx_info in existing_indexes.values():
            keys = [k[0] for k in idx_info["key"]]
            existing_keys.append(keys)

        for req_keys in required:
            found = any(
                all(k in existing for k in req_keys)
                for existing in existing_keys
            )
            key_str = ", ".join(req_keys)
            if found:
                check_pass(f"{collection}: 인덱스 [{key_str}] 존재")
            else:
                check_fail(f"{collection}: 인덱스 [{key_str}] 없음 — 생성 필요")


# =============================================================================
# 6. MongoDB 커넥션 테스트
# =============================================================================
def check_mongodb_connection():
    print(f"\n{BOLD}6. MongoDB 커넥션 테스트{NC}")

    try:
        client = MongoClient(
            MONGO_CONFIG["host"],
            MONGO_CONFIG["port"],
            serverSelectionTimeoutMS=5000,
        )
        result = client.admin.command("ping")
        if result.get("ok") == 1.0:
            check_pass(f"MongoDB ping 성공 ({MONGO_CONFIG['host']}:{MONGO_CONFIG['port']})")
        else:
            check_fail("MongoDB ping 실패")
    except Exception as e:
        check_fail(f"MongoDB 연결 실패: {e}")


# =============================================================================
# 결과 출력
# =============================================================================
def print_verdict():
    print(f"\n{'=' * 60}")
    print(f" 컷오버 준비 상태 검증 결과")
    print(f"{'=' * 60}")
    print(f"  {GREEN}PASS: {checks_pass}{NC}")
    print(f"  {RED}FAIL: {checks_fail}{NC}")
    print(f"  {YELLOW}WARN: {checks_warn}{NC}")
    print()

    if checks_fail == 0:
        print(f"  {GREEN}{BOLD}GO — 컷오버를 진행할 수 있습니다.{NC}")
        print()
        print("  다음 단계:")
        print("    1. 백엔드 팀에 컷오버 시작 공지")
        print("    2. 신규 방 → MongoDB 라우팅 배포")
        print("    3. 기존 방 자연 종료 대기 (최대 30분)")
        print("    4. DMS Task 중지")
    else:
        print(f"  {RED}{BOLD}NO-GO — FAIL 항목을 해결한 후 다시 검증하세요.{NC}")

    print(f"{'=' * 60}")


def main():
    task_arn = check_dms_task_status()
    check_cdc_lag()
    check_data_validation(task_arn)
    check_row_counts()
    check_mongodb_indexes()
    check_mongodb_connection()
    print_verdict()

    sys.exit(0 if checks_fail == 0 else 1)


if __name__ == "__main__":
    main()
