#!/bin/bash
#
# Doktori 부하테스트 환경 설정 스크립트
# 대상: AWS Lightsail Ubuntu 인스턴스
#
# 사용법:
#   chmod +x setup.sh
#   ./setup.sh
#

set -e

echo "=========================================="
echo " Doktori 부하테스트 환경 설정"
echo "=========================================="

# 시스템 업데이트
echo "[1/4] 시스템 업데이트..."
sudo apt-get update -y
sudo apt-get upgrade -y

# k6 설치
echo "[2/4] k6 설치..."
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
    --keyserver hkp://keyserver.ubuntu.com:80 \
    --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | \
    sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update -y
sudo apt-get install -y k6

# Git 설치 (없을 경우)
echo "[3/4] Git 설치..."
sudo apt-get install -y git

# 테스트 코드 클론 (또는 수동 업로드)
echo "[4/4] 테스트 코드 준비..."
if [ ! -d "load-tests" ]; then
    echo "load-tests 디렉토리가 없습니다."
    echo "다음 중 하나를 실행하세요:"
    echo "  1. git clone <your-repo> 후 load-tests 폴더 사용"
    echo "  2. scp로 로컬에서 업로드: scp -r load-tests ubuntu@<ip>:~/"
fi

echo ""
echo "=========================================="
echo " 설치 완료!"
echo "=========================================="
echo ""
echo "k6 버전: $(k6 version)"
echo ""
echo "다음 단계:"
echo "  1. 환경변수 설정:"
echo "     export BASE_URL=\"https://your-api.com/api\""
echo "     export JWT_TOKEN=\"your-token\""
echo ""
echo "  2. 테스트 실행:"
echo "     cd load-tests"
echo "     k6 run k6/scenarios/smoke.js"
echo ""
