#!/usr/bin/env python3
"""
02_validate_fullload.py — Full Load 후 데이터 정합성 검증

MySQL과 MongoDB 간 row count 비교 + 샘플 데이터 필드별 비교를 수행한다.
검증 결과를 JSON 리포트로 저장하고 콘솔에 요약을 출력한다.
"""

import os
import sys
import json
import random
from datetime import datetime, timezone
from dataclasses import dataclass, field, asdict

try:
    import mysql.connector
    from pymongo import MongoClient
except ImportError:
    print("필요한 패키지를 설치하세요:")
    print("  pip install mysql-connector-python pymongo")
    sys.exit(1)

# ─── 설정 ───
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

SAMPLE_SIZE = int(os.environ.get("SAMPLE_SIZE", 100))

# MySQL 테이블 → MongoDB 컬렉션 매핑
TABLE_MAP = {
    "chatting_rooms": "chatting_rooms",
    "room_rounds": "room_rounds",
    "chatting_room_members": "chatting_room_members",
    "messages": "messages",
    "quizzes": "quizzes",
    "quiz_choices": "quiz_choices",
}

# 테이블별 Primary Key
PK_MAP = {
    "chatting_rooms": "id",
    "room_rounds": "id",
    "chatting_room_members": "id",
    "messages": "id",
    "quizzes": "id",
    "quiz_choices": "id",
}

# 비교에서 제외할 컬럼 (DMS가 추가하거나 변환이 다른 필드)
SKIP_COLUMNS = {"_id"}


@dataclass
class TableValidation:
    table: str
    collection: str
    mysql_count: int = 0
    mongo_count: int = 0
    count_match: bool = False
    samples_checked: int = 0
    samples_matched: int = 0
    mismatches: list = field(default_factory=list)

    @property
    def sample_match_rate(self) -> float:
        if self.samples_checked == 0:
            return 0.0
        return self.samples_matched / self.samples_checked * 100

    @property
    def passed(self) -> bool:
        return self.count_match and self.samples_checked == self.samples_matched


@dataclass
class ValidationReport:
    timestamp: str = ""
    tables: list = field(default_factory=list)
    total_pass: int = 0
    total_fail: int = 0

    @property
    def all_passed(self) -> bool:
        return self.total_fail == 0


def get_mysql_connection():
    return mysql.connector.connect(**MYSQL_CONFIG)


def get_mongo_db():
    client = MongoClient(MONGO_CONFIG["host"], MONGO_CONFIG["port"])
    return client[MONGO_CONFIG["db"]]


def get_mysql_count(cursor, table: str) -> int:
    cursor.execute(f"SELECT COUNT(*) FROM `{table}`")
    return cursor.fetchone()[0]


def get_mongo_count(db, collection: str) -> int:
    return db[collection].count_documents({})


def get_mysql_sample_ids(cursor, table: str, pk: str, size: int) -> list:
    cursor.execute(f"SELECT `{pk}` FROM `{table}` ORDER BY `{pk}`")
    all_ids = [row[0] for row in cursor.fetchall()]
    if len(all_ids) <= size:
        return all_ids
    return random.sample(all_ids, size)


def get_mysql_row(cursor, table: str, pk: str, pk_value) -> dict:
    cursor.execute(f"SELECT * FROM `{table}` WHERE `{pk}` = %s", (pk_value,))
    columns = [desc[0] for desc in cursor.description]
    row = cursor.fetchone()
    if row is None:
        return {}
    result = {}
    for col, val in zip(columns, row):
        if isinstance(val, datetime):
            result[col] = val.replace(tzinfo=timezone.utc).isoformat()
        elif isinstance(val, bytes):
            result[col] = val.decode("utf-8", errors="replace")
        else:
            result[col] = val
    return result


def get_mongo_row(db, collection: str, pk: str, pk_value) -> dict:
    doc = db[collection].find_one({pk: pk_value})
    if doc is None:
        return {}
    result = {}
    for k, v in doc.items():
        if k in SKIP_COLUMNS:
            continue
        if isinstance(v, datetime):
            result[k] = v.replace(tzinfo=timezone.utc).isoformat()
        else:
            result[k] = v
    return result


def compare_rows(mysql_row: dict, mongo_row: dict) -> list:
    """두 row를 비교하여 불일치 필드 목록을 반환한다."""
    diffs = []
    all_keys = set(mysql_row.keys()) | set(mongo_row.keys()) - SKIP_COLUMNS

    for key in all_keys:
        if key in SKIP_COLUMNS:
            continue
        m_val = mysql_row.get(key)
        g_val = mongo_row.get(key)

        # 숫자 타입 비교 (int vs float)
        if isinstance(m_val, (int, float)) and isinstance(g_val, (int, float)):
            if abs(float(m_val) - float(g_val)) > 0.001:
                diffs.append({
                    "field": key,
                    "mysql": str(m_val),
                    "mongo": str(g_val),
                })
        elif str(m_val) != str(g_val):
            diffs.append({
                "field": key,
                "mysql": str(m_val)[:200],
                "mongo": str(g_val)[:200],
            })

    return diffs


def validate_table(mysql_cursor, mongo_db, table: str, collection: str) -> TableValidation:
    """단일 테이블에 대해 count 비교 + 샘플 데이터 비교를 수행한다."""
    v = TableValidation(table=table, collection=collection)
    pk = PK_MAP[table]

    # 1. Count 비교
    v.mysql_count = get_mysql_count(mysql_cursor, table)
    v.mongo_count = get_mongo_count(mongo_db, collection)
    v.count_match = v.mysql_count == v.mongo_count

    # 2. 샘플 데이터 비교
    sample_ids = get_mysql_sample_ids(mysql_cursor, table, pk, SAMPLE_SIZE)
    v.samples_checked = len(sample_ids)

    for pk_value in sample_ids:
        mysql_row = get_mysql_row(mysql_cursor, table, pk, pk_value)
        mongo_row = get_mongo_row(mongo_db, collection, pk, pk_value)

        if not mongo_row:
            v.mismatches.append({
                "pk": pk_value,
                "error": "MongoDB에서 해당 레코드를 찾을 수 없음",
            })
            continue

        diffs = compare_rows(mysql_row, mongo_row)
        if diffs:
            v.mismatches.append({
                "pk": pk_value,
                "diffs": diffs,
            })
        else:
            v.samples_matched += 1

    return v


def print_report(report: ValidationReport):
    """검증 결과를 콘솔에 출력한다."""
    print("\n" + "=" * 70)
    print(" Full Load 데이터 정합성 검증 결과")
    print("=" * 70)
    print(f" 검증 시각: {report.timestamp}")
    print()

    for v in report.tables:
        status = "\033[32m[PASS]\033[0m" if v.passed else "\033[31m[FAIL]\033[0m"
        print(f"  {status} {v.table}")
        print(f"         Row Count: MySQL={v.mysql_count}, MongoDB={v.mongo_count}"
              f" {'(일치)' if v.count_match else '(불일치!)'}")
        print(f"         샘플 검증: {v.samples_matched}/{v.samples_checked}"
              f" ({v.sample_match_rate:.1f}%)")

        if v.mismatches:
            print(f"         불일치 {len(v.mismatches)}건:")
            for m in v.mismatches[:5]:  # 최대 5건만 출력
                if "error" in m:
                    print(f"           PK={m['pk']}: {m['error']}")
                else:
                    diff_fields = ", ".join(d["field"] for d in m["diffs"])
                    print(f"           PK={m['pk']}: 불일치 필드=[{diff_fields}]")
            if len(v.mismatches) > 5:
                print(f"           ... 외 {len(v.mismatches) - 5}건 (리포트 파일 참조)")
        print()

    print("-" * 70)
    total = len(report.tables)
    print(f" 결과: {report.total_pass}/{total} 테이블 통과,"
          f" {report.total_fail}/{total} 테이블 실패")

    if report.all_passed:
        print("\033[32m 모든 테이블 검증 통과. CDC 단계로 진행 가능합니다.\033[0m")
    else:
        print("\033[31m 불일치가 발견되었습니다. 리포트를 확인하고 원인을 분석하세요.\033[0m")
    print("=" * 70)


def main():
    report = ValidationReport(
        timestamp=datetime.now(timezone.utc).isoformat(),
    )

    mysql_conn = get_mysql_connection()
    mysql_cursor = mysql_conn.cursor()
    mongo_db = get_mongo_db()

    try:
        for table, collection in TABLE_MAP.items():
            print(f"검증 중: {table} → {collection} ...")
            v = validate_table(mysql_cursor, mongo_db, table, collection)
            report.tables.append(v)

            if v.passed:
                report.total_pass += 1
            else:
                report.total_fail += 1
    finally:
        mysql_cursor.close()
        mysql_conn.close()

    # 콘솔 출력
    print_report(report)

    # JSON 리포트 저장
    report_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..",
        f"validation_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json",
    )
    report_data = {
        "timestamp": report.timestamp,
        "total_pass": report.total_pass,
        "total_fail": report.total_fail,
        "tables": [],
    }
    for v in report.tables:
        report_data["tables"].append({
            "table": v.table,
            "collection": v.collection,
            "mysql_count": v.mysql_count,
            "mongo_count": v.mongo_count,
            "count_match": v.count_match,
            "samples_checked": v.samples_checked,
            "samples_matched": v.samples_matched,
            "sample_match_rate": v.sample_match_rate,
            "passed": v.passed,
            "mismatches": v.mismatches[:20],  # 최대 20건
        })

    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(report_data, f, ensure_ascii=False, indent=2)

    print(f"\n리포트 저장: {report_path}")

    sys.exit(0 if report.all_passed else 1)


if __name__ == "__main__":
    main()
