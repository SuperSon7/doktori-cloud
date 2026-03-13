#!/usr/bin/env bash
# =============================================================================
# 05_rollback.sh — 마이그레이션 롤백 자동화
# 컷오버 후 문제 발생 시 MySQL로 롤백하는 절차를 자동화한다.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── 설정 ───
PROJECT_PREFIX="${PROJECT_PREFIX:-doktori}"
TASK_ID="${PROJECT_PREFIX}-chat-migration"
REGION="${AWS_REGION:-ap-northeast-2}"

# ─── 롤백 Phase 선택 ───
echo ""
echo -e "${BOLD}=========================================="
echo " 마이그레이션 롤백"
echo -e "==========================================${NC}"
echo ""
echo "현재 마이그레이션 Phase를 선택하세요:"
echo ""
echo "  1) Phase 1-2: CDC 동기화 중 (MySQL이 source of truth)"
echo "     → DMS Task 중지만 하면 됨"
echo ""
echo "  2) Phase 3: 컷오버 후 (신규 방이 MongoDB에 생성 중)"
echo "     → 앱 롤백 + MongoDB 신규 데이터 MySQL로 역이전 + DMS 재시작"
echo ""
echo "  3) Phase 0: 인프라 준비 단계"
echo "     → DMS 리소스만 정리"
echo ""
read -rp "Phase 선택 (1/2/3): " PHASE

case "$PHASE" in
    1)
        echo ""
        info "Phase 1-2 롤백: DMS Task 중지"
        echo ""

        TASK_ARN=$(aws dms describe-replication-tasks \
            --filters "Name=replication-task-id,Values=${TASK_ID}" \
            --query "ReplicationTasks[0].ReplicationTaskArn" \
            --output text \
            --region "$REGION" 2>/dev/null || echo "")

        if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
            warn "Task '${TASK_ID}'을 찾을 수 없습니다"
            exit 0
        fi

        TASK_STATUS=$(aws dms describe-replication-tasks \
            --filters "Name=replication-task-id,Values=${TASK_ID}" \
            --query "ReplicationTasks[0].Status" \
            --output text \
            --region "$REGION")

        if [ "$TASK_STATUS" = "running" ]; then
            read -rp "DMS Task를 중지하시겠습니까? (y/N): " CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                aws dms stop-replication-task \
                    --replication-task-arn "$TASK_ARN" \
                    --region "$REGION"
                info "DMS Task 중지 요청 완료"

                info "Task 중지 대기 중..."
                aws dms wait replication-task-stopped \
                    --filters "Name=replication-task-id,Values=${TASK_ID}" \
                    --region "$REGION"
                info "DMS Task 중지 완료"
            else
                warn "롤백 취소됨"
                exit 0
            fi
        else
            info "Task 상태: ${TASK_STATUS} (이미 중지됨)"
        fi

        echo ""
        info "Phase 1-2 롤백 완료. MySQL이 source of truth를 유지합니다."
        info "MongoDB의 데이터는 그대로 남아 있습니다 (필요 시 정리)."
        ;;

    2)
        echo ""
        warn "Phase 3 롤백: 컷오버 후 롤백"
        echo ""
        echo -e "${RED}${BOLD}주의: 컷오버 후 MongoDB에만 존재하는 신규 데이터가 있을 수 있습니다.${NC}"
        echo ""
        read -rp "정말 롤백을 진행하시겠습니까? (yes/no): " CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            warn "롤백 취소됨"
            exit 0
        fi

        # Step 1: 앱 롤백 안내
        echo ""
        info "Step 1: 앱 롤백 배포"
        echo "  백엔드 팀에 연락하여 이전 버전(MySQL 사용)으로 롤백 배포하세요."
        echo "  배포 후 Enter를 눌러 다음 단계로 진행하세요."
        read -rp "  [Enter to continue] "

        # Step 2: 활성 세션 확인
        info "Step 2: 활성 채팅 세션 확인"
        echo "  현재 MongoDB에서 활성 중인 채팅 방이 있는지 확인합니다."
        echo "  (앱 롤백 후 새 방은 MySQL에 생성되므로, 기존 활성 방만 확인)"
        echo ""

        MONGO_HOST="${MONGO_HOST:-localhost}"
        MONGO_PORT="${MONGO_PORT:-27017}"
        MONGO_DB="${MONGO_DB:-doktori_chat}"

        if command -v mongosh &> /dev/null; then
            ACTIVE_ROOMS=$(mongosh --host "$MONGO_HOST" --port "$MONGO_PORT" \
                --eval "db.chatting_rooms.countDocuments({status: 'CHATTING'})" \
                --quiet "$MONGO_DB" 2>/dev/null || echo "확인 불가")
            info "활성 채팅 방 수: ${ACTIVE_ROOMS}"
            if [ "$ACTIVE_ROOMS" != "0" ] && [ "$ACTIVE_ROOMS" != "확인 불가" ]; then
                warn "활성 세션이 종료될 때까지 대기하세요 (최대 30분)"
                echo "  세션이 자연 종료된 후 다음 단계로 진행하세요."
                read -rp "  [Enter to continue] "
            fi
        else
            warn "mongosh가 설치되지 않음 — 수동으로 활성 세션을 확인하세요"
            read -rp "  [Enter to continue] "
        fi

        # Step 3: DMS Task 재시작 (역방향은 불필요 — 앱이 다시 MySQL에 쓰므로)
        info "Step 3: DMS Task 상태 확인"
        TASK_ARN=$(aws dms describe-replication-tasks \
            --filters "Name=replication-task-id,Values=${TASK_ID}" \
            --query "ReplicationTasks[0].ReplicationTaskArn" \
            --output text \
            --region "$REGION" 2>/dev/null || echo "")

        if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
            TASK_STATUS=$(aws dms describe-replication-tasks \
                --filters "Name=replication-task-id,Values=${TASK_ID}" \
                --query "ReplicationTasks[0].Status" \
                --output text \
                --region "$REGION")

            if [ "$TASK_STATUS" = "stopped" ]; then
                info "DMS Task가 중지 상태 — 앱이 MySQL에 직접 쓰므로 재시작 불필요"
            elif [ "$TASK_STATUS" = "running" ]; then
                info "DMS Task가 여전히 실행 중 — MySQL → MongoDB 동기화 유지"
            fi
        fi

        echo ""
        info "Phase 3 롤백 완료."
        warn "MongoDB에만 존재하는 컷오버 후 신규 데이터를 확인하세요:"
        echo "  - 컷오버 시점 이후 생성된 방/메시지가 MongoDB에만 있을 수 있음"
        echo "  - 필요 시 별도 스크립트로 MongoDB → MySQL 역이전 수행"
        ;;

    3)
        echo ""
        info "Phase 0 롤백: DMS 리소스 정리"
        echo ""

        read -rp "DMS 리소스를 삭제하시겠습니까? (yes/no): " CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            warn "롤백 취소됨"
            exit 0
        fi

        # Task 삭제
        TASK_ARN=$(aws dms describe-replication-tasks \
            --filters "Name=replication-task-id,Values=${TASK_ID}" \
            --query "ReplicationTasks[0].ReplicationTaskArn" \
            --output text \
            --region "$REGION" 2>/dev/null || echo "None")

        if [ "$TASK_ARN" != "None" ] && [ -n "$TASK_ARN" ]; then
            # 실행 중이면 먼저 중지
            TASK_STATUS=$(aws dms describe-replication-tasks \
                --filters "Name=replication-task-id,Values=${TASK_ID}" \
                --query "ReplicationTasks[0].Status" \
                --output text \
                --region "$REGION")
            if [ "$TASK_STATUS" = "running" ]; then
                info "Task 중지 중..."
                aws dms stop-replication-task --replication-task-arn "$TASK_ARN" --region "$REGION"
                aws dms wait replication-task-stopped \
                    --filters "Name=replication-task-id,Values=${TASK_ID}" --region "$REGION"
            fi
            info "Task 삭제 중..."
            aws dms delete-replication-task --replication-task-arn "$TASK_ARN" --region "$REGION"
            aws dms wait replication-task-deleted \
                --filters "Name=replication-task-id,Values=${TASK_ID}" --region "$REGION"
            info "Task 삭제 완료"
        fi

        # Endpoints 삭제
        for EP_ID in "${PROJECT_PREFIX}-mysql-source" "${PROJECT_PREFIX}-mongo-target"; do
            EP_ARN=$(aws dms describe-endpoints \
                --filters "Name=endpoint-id,Values=${EP_ID}" \
                --query "Endpoints[0].EndpointArn" \
                --output text \
                --region "$REGION" 2>/dev/null || echo "None")
            if [ "$EP_ARN" != "None" ] && [ -n "$EP_ARN" ]; then
                info "Endpoint '${EP_ID}' 삭제 중..."
                aws dms delete-endpoint --endpoint-arn "$EP_ARN" --region "$REGION"
                info "Endpoint '${EP_ID}' 삭제 완료"
            fi
        done

        # Replication Instance 삭제
        RI_ID="${PROJECT_PREFIX}-dms-repl"
        RI_ARN=$(aws dms describe-replication-instances \
            --filters "Name=replication-instance-id,Values=${RI_ID}" \
            --query "ReplicationInstances[0].ReplicationInstanceArn" \
            --output text \
            --region "$REGION" 2>/dev/null || echo "None")
        if [ "$RI_ARN" != "None" ] && [ -n "$RI_ARN" ]; then
            info "Replication Instance '${RI_ID}' 삭제 중... (수 분 소요)"
            aws dms delete-replication-instance --replication-instance-arn "$RI_ARN" --region "$REGION"
            info "Replication Instance 삭제 요청 완료"
        fi

        echo ""
        info "Phase 0 롤백 완료. 모든 DMS 리소스가 삭제되었습니다."
        ;;

    *)
        error "잘못된 선택입니다."
        exit 1
        ;;
esac
