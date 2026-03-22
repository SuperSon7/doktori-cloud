#!/usr/bin/env bash
# =============================================================================
# ArgoCD 통합 부트스트랩 스크립트
# install-argocd.sh + setup-argocd.sh를 단계별로 실행 가능하게 통합
#
# 사용법: master 노드에서 실행
#   chmod +x bootstrap-argocd.sh
#   ./bootstrap-argocd.sh                # 전체 실행 (install → setup → app-of-apps)
#   ./bootstrap-argocd.sh --install      # ArgoCD Helm 설치만
#   ./bootstrap-argocd.sh --setup        # Git 연결 + 보안 + 비밀번호 변경
#   ./bootstrap-argocd.sh --app-of-apps  # root Application 배포
#
# 단계 조합 가능:
#   ./bootstrap-argocd.sh --install --setup
#   ./bootstrap-argocd.sh --setup --skip-etcd --skip-kubelet
#
# 옵션:
#   --skip-etcd     etcd 암호화 건너뜀 (--setup 단계에서)
#   --skip-kubelet  kubelet 보안 설정 건너뜀 (--setup 단계에서)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# ---------------------------------------------------------------------------
# 인자 파싱
# ---------------------------------------------------------------------------
RUN_INSTALL=false
RUN_SETUP=false
RUN_APP_OF_APPS=false
SKIP_ETCD=false
SKIP_KUBELET=false
EXPLICIT_STAGE=false

for arg in "$@"; do
  case "$arg" in
    --install)      RUN_INSTALL=true;     EXPLICIT_STAGE=true ;;
    --setup)        RUN_SETUP=true;       EXPLICIT_STAGE=true ;;
    --app-of-apps)  RUN_APP_OF_APPS=true; EXPLICIT_STAGE=true ;;
    --skip-etcd)    SKIP_ETCD=true ;;
    --skip-kubelet) SKIP_KUBELET=true ;;
    *)
      echo "[ERROR] 알 수 없는 옵션: $arg"
      echo "사용법: $0 [--install] [--setup] [--app-of-apps] [--skip-etcd] [--skip-kubelet]"
      exit 1
      ;;
  esac
done

# 인자 없으면 전체 실행
if [ "$EXPLICIT_STAGE" = false ]; then
  RUN_INSTALL=true
  RUN_SETUP=true
  RUN_APP_OF_APPS=true
fi

# ---------------------------------------------------------------------------
# 유틸리티
# ---------------------------------------------------------------------------
log_header() {
  echo ""
  echo "============================================="
  echo " $1"
  echo "============================================="
}

log_step() {
  echo ""
  echo "[$1] $2"
}

# ---------------------------------------------------------------------------
# [INSTALL] ArgoCD Helm 설치
# ---------------------------------------------------------------------------
do_install() {
  log_header "ArgoCD 설치 (Helm)"

  # 0. Helm 확인
  if ! command -v helm &>/dev/null; then
    echo "[ERROR] Helm이 설치되어 있지 않습니다."
    exit 1
  fi

  # 1. NetworkPolicy
  log_step "1/4" "NetworkPolicy 적용..."
  echo "  default-deny + NGF→api + NGF→chat + monitoring→apps"

  kubectl apply -f "${SCRIPT_DIR}/manifests/security/netpol-all.yaml"

  echo "  → 서비스 동작 확인 필요:"
  echo "    curl http://<NLB_DNS>/api/health"
  echo "    curl http://<NLB_DNS>/api/chat/health"

  # 2. External Secrets Operator (Helm)
  log_step "2/4" "External Secrets Operator 설치..."

  helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
  helm repo update external-secrets

  if helm status external-secrets -n external-secrets &>/dev/null; then
    echo "  → 이미 설치됨."
  else
    helm install external-secrets external-secrets/external-secrets \
      --namespace external-secrets \
      --create-namespace \
      --version "2.2.0" \
      --set installCRDs=true
    echo "  → ESO 설치 완료. CRD 등록 대기..."
    for i in $(seq 1 30); do
      if kubectl get crd clustersecretstores.external-secrets.io &>/dev/null; then
        echo "  → CRD 등록 완료"
        break
      fi
      sleep 5
    done
  fi

  # 3. ArgoCD (Helm)
  log_step "3/4" "ArgoCD 설치..."

  helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
  helm repo update argo

  if helm status argocd -n argocd &>/dev/null; then
    echo "  → 이미 설치됨. 업그레이드 확인..."
    helm upgrade argocd argo/argo-cd \
      --namespace argocd \
      --version "${ARGOCD_CHART_VERSION}" \
      -f "${SCRIPT_DIR}/helm/argocd-values.yaml"
  else
    helm install argocd argo/argo-cd \
      --namespace argocd \
      --create-namespace \
      --version "${ARGOCD_CHART_VERSION}" \
      -f "${SCRIPT_DIR}/helm/argocd-values.yaml"
  fi

  echo "  → ArgoCD Pod 대기 중..."
  kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=argocd-server \
    -n argocd --timeout=120s 2>/dev/null || true

  # 3. 초기 비밀번호 + 접근 안내
  log_step "4/4" "ArgoCD 접근 정보..."

  ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "아직 생성 안 됨")

  echo ""
  echo "  Username: admin"
  echo "  Password: ${ARGOCD_PASSWORD}"
  echo ""
  echo "  접근 방법 (port-forward):"
  echo "    kubectl port-forward svc/argocd-server -n argocd 8443:443 --address=0.0.0.0"
  echo "    → https://localhost:8443"
  echo ""
  echo "  접근 방법 (NodePort):"
  echo "    kubectl patch svc argocd-server -n argocd -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"https\",\"port\":443,\"nodePort\":${ARGOCD_NODEPORT},\"targetPort\":8080}]}}'"
  echo "    → https://<Worker-IP>:${ARGOCD_NODEPORT}"

  log_header "ArgoCD 설치 완료"
}

# ---------------------------------------------------------------------------
# [SETUP] Git 연결, 보안 설정, 비밀번호 변경
# ---------------------------------------------------------------------------
do_setup() {
  log_header "ArgoCD 초기 설정"

  # --- [A] Git 저장소 연결 ---
  log_step "A" "Git 저장소 연결..."

  if [ -n "${GIT_REPO_URL:-}" ]; then
    REPO_URL="${GIT_REPO_URL}"
    echo "  → config.env에서 읽음: ${REPO_URL}"
  else
    read -rp "  Git 저장소 URL: " REPO_URL
  fi

  if [ -n "${GIT_USERNAME:-}" ]; then
    USERNAME="${GIT_USERNAME}"
  else
    read -rp "  Git Username: " USERNAME
  fi

  if [ -n "${GIT_PAT:-}" ]; then
    PAT="${GIT_PAT}"
  else
    read -rsp "  Git PAT (Personal Access Token): " PAT
    echo ""
  fi

  if [ -z "$REPO_URL" ] || [ -z "$USERNAME" ] || [ -z "$PAT" ]; then
    echo "  [WARN] Git 정보 미입력. 저장소 연결을 건너뜁니다."
  else
    # 기존 Secret이 있으면 삭제 후 재생성
    kubectl delete secret private-repo-creds -n argocd 2>/dev/null || true

    kubectl create secret generic private-repo-creds \
      --namespace argocd \
      --from-literal=type=git \
      --from-literal=url="${REPO_URL}" \
      --from-literal=username="${USERNAME}" \
      --from-literal=password="${PAT}"

    kubectl label secret private-repo-creds -n argocd \
      argocd.argoproj.io/secret-type=repository --overwrite

    echo "  → Git 저장소 연결 완료"

    # Application은 root-app.yaml → apps/ 폴더에서 App-of-Apps 패턴으로 관리
    # (구 application-*.yaml 방식 제거됨)

    # REPO_URL을 파일 스코프로 export (app-of-apps에서 사용)
    export RESOLVED_REPO_URL="${REPO_URL}"
  fi

  # --- [B] etcd 암호화 ---
  echo ""
  if [ "$SKIP_ETCD" = true ]; then
    echo "[B] etcd 암호화 — 건너뜀 (--skip-etcd)"
  else
    log_step "B" "etcd 암호화 설정..."

    ENCRYPTION_CONFIG="/etc/kubernetes/encryption-config.yaml"

    if [ -f "$ENCRYPTION_CONFIG" ]; then
      echo "  → 이미 설정됨: ${ENCRYPTION_CONFIG}"
    else
      ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

      sudo tee "$ENCRYPTION_CONFIG" > /dev/null <<ENCEOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
ENCEOF

      sudo chmod 600 "$ENCRYPTION_CONFIG"
      echo "  → ${ENCRYPTION_CONFIG} 생성됨"

      APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
      if [ -f "$APISERVER_MANIFEST" ]; then
        if grep -q "encryption-provider-config" "$APISERVER_MANIFEST"; then
          echo "  → kube-apiserver에 이미 encryption 설정 있음"
        else
          echo "  → kube-apiserver manifest 패치..."
          TEMP_FILE=$(mktemp)
          cp "$APISERVER_MANIFEST" "$TEMP_FILE"

          sudo sed -i '/- --tls-private-key-file/a\    - --encryption-provider-config=\/etc\/kubernetes\/encryption-config.yaml' "$APISERVER_MANIFEST"

          if ! grep -q "encryption-config" "$APISERVER_MANIFEST"; then
            sudo sed -i '/name: k8s-certs/i\    - mountPath: \/etc\/kubernetes\/encryption-config.yaml\n      name: encryption-config\n      readOnly: true' "$APISERVER_MANIFEST"
            sudo sed -i '/name: k8s-certs/,/path:/!b;/name: k8s-certs/{N;N;a\  - hostPath:\n      path: \/etc\/kubernetes\/encryption-config.yaml\n      type: File\n    name: encryption-config
}' "$APISERVER_MANIFEST"
          fi

          echo "  → kube-apiserver가 자동으로 재시작됩니다 (static pod)."
          echo "  → 기존 Secret 재암호화: kubectl get secrets --all-namespaces -o json | kubectl replace -f -"
        fi
      else
        echo "  [WARN] ${APISERVER_MANIFEST} 없음. kubeadm 클러스터인지 확인하세요."
      fi
    fi
  fi

  # --- [C] kubelet 보안 설정 ---
  echo ""
  if [ "$SKIP_KUBELET" = true ]; then
    echo "[C] kubelet 보안 — 건너뜀 (--skip-kubelet)"
  else
    log_step "C" "kubelet 보안 설정..."

    KUBELET_CONFIG="/var/lib/kubelet/config.yaml"

    if [ ! -f "$KUBELET_CONFIG" ]; then
      echo "  [WARN] ${KUBELET_CONFIG} 없음. 건너뜁니다."
    else
      CHANGED=false

      if grep -q "enabled: true" <(grep -A1 "anonymous:" "$KUBELET_CONFIG"); then
        sudo sed -i '/anonymous:/,/enabled:/{s/enabled: true/enabled: false/}' "$KUBELET_CONFIG"
        CHANGED=true
        echo "  → anonymous auth 비활성화"
      else
        echo "  → anonymous auth 이미 비활성화됨"
      fi

      if grep -q "readOnlyPort: 10255" "$KUBELET_CONFIG"; then
        sudo sed -i 's/readOnlyPort: 10255/readOnlyPort: 0/' "$KUBELET_CONFIG"
        CHANGED=true
        echo "  → readOnlyPort 비활성화 (10255→0)"
      elif grep -q "readOnlyPort: 0" "$KUBELET_CONFIG"; then
        echo "  → readOnlyPort 이미 비활성화됨"
      else
        echo "readOnlyPort: 0" | sudo tee -a "$KUBELET_CONFIG" > /dev/null
        CHANGED=true
        echo "  → readOnlyPort: 0 추가"
      fi

      if [ "$CHANGED" = true ]; then
        echo "  → kubelet 재시작..."
        sudo systemctl restart kubelet
        echo "  → kubelet 보안 설정 완료"
        echo ""
        echo "  ⚠ 워커 노드에서도 동일하게 실행해야 합니다:"
        echo "    sudo sed -i '/anonymous:/,/enabled:/{s/enabled: true/enabled: false/}' /var/lib/kubelet/config.yaml"
        echo "    sudo sed -i 's/readOnlyPort: 10255/readOnlyPort: 0/' /var/lib/kubelet/config.yaml"
        echo "    sudo systemctl restart kubelet"
      fi
    fi
  fi

  # --- [D] ArgoCD 비밀번호 변경 ---
  log_step "D" "ArgoCD 비밀번호 변경..."

  read -rsp "  새 ArgoCD admin 비밀번호 (빈 값이면 건너뜀): " NEW_PASSWORD
  echo ""

  if [ -z "$NEW_PASSWORD" ]; then
    echo "  → 건너뜀. 초기 비밀번호 유지."
  else
    if command -v htpasswd &>/dev/null; then
      BCRYPT_HASH=$(htpasswd -nbBC 10 "" "$NEW_PASSWORD" | tr -d ':\n' | sed 's/$2y/$2a/')
    elif command -v python3 &>/dev/null; then
      BCRYPT_HASH=$(python3 -c "
import bcrypt
password = '${NEW_PASSWORD}'.encode('utf-8')
hashed = bcrypt.hashpw(password, bcrypt.gensalt(rounds=10))
print(hashed.decode('utf-8'))
" 2>/dev/null || echo "")
    else
      echo "  [WARN] htpasswd 또는 python3+bcrypt 필요. 수동으로 변경하세요:"
      echo "    argocd account update-password"
      BCRYPT_HASH=""
    fi

    if [ -n "$BCRYPT_HASH" ]; then
      kubectl -n argocd patch secret argocd-secret \
        -p "{\"stringData\":{\"admin.password\":\"${BCRYPT_HASH}\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
      echo "  → 비밀번호 변경 완료"

      kubectl delete secret argocd-initial-admin-secret -n argocd 2>/dev/null || true
      echo "  → 초기 비밀번호 Secret 삭제됨"
    fi
  fi

  log_header "ArgoCD 설정 완료"
}

# ---------------------------------------------------------------------------
# [APP-OF-APPS] Root Application 배포
# ---------------------------------------------------------------------------
do_app_of_apps() {
  log_header "ArgoCD App-of-Apps 배포"

  ROOT_APP="${SCRIPT_DIR}/manifests/argocd/root-app.yaml"

  if [ ! -f "$ROOT_APP" ]; then
    echo "[ERROR] root-app.yaml을 찾을 수 없습니다: ${ROOT_APP}"
    exit 1
  fi

  # REPO_URL 결정: setup에서 넘어온 값 > config.env > 인터랙티브
  REPO_URL="${RESOLVED_REPO_URL:-${GIT_REPO_URL:-}}"
  if [ -z "$REPO_URL" ]; then
    read -rp "  Git 저장소 URL (root-app.yaml에 주입): " REPO_URL
  fi

  if [ -z "$REPO_URL" ]; then
    echo "[ERROR] Git 저장소 URL이 필요합니다."
    exit 1
  fi

  # 멱등성: 이미 배포된 경우 확인
  if kubectl get application doktori-root -n argocd &>/dev/null; then
    echo "  → doktori-root Application이 이미 존재합니다. 업데이트합니다..."
  fi

  sed "s|__GIT_REPO_URL__|${REPO_URL}|g" "$ROOT_APP" | kubectl apply -f -
  echo "  → root-app.yaml 배포 완료"

  echo ""
  echo "  ArgoCD가 자동으로 하위 Application을 동기화합니다."
  echo "  확인: kubectl get applications -n argocd"

  log_header "App-of-Apps 배포 완료"
}

# ---------------------------------------------------------------------------
# 실행
# ---------------------------------------------------------------------------
log_header "ArgoCD 부트스트랩 시작"

STAGES=()
$RUN_INSTALL     && STAGES+=("install")
$RUN_SETUP       && STAGES+=("setup")
$RUN_APP_OF_APPS && STAGES+=("app-of-apps")

echo "  실행 단계: ${STAGES[*]}"
echo "  skip-etcd: ${SKIP_ETCD}, skip-kubelet: ${SKIP_KUBELET}"

$RUN_INSTALL     && do_install
$RUN_SETUP       && do_setup
$RUN_APP_OF_APPS && do_app_of_apps

# ---------------------------------------------------------------------------
# 최종 상태 출력
# ---------------------------------------------------------------------------
log_header "부트스트랩 완료 — 최종 상태"

echo ""
echo "--- ArgoCD Pods ---"
kubectl get pods -n argocd 2>/dev/null || echo "  argocd namespace 없음"

echo ""
echo "--- ArgoCD Applications ---"
kubectl get applications -n argocd 2>/dev/null || echo "  아직 Application 없음"

echo ""
echo "접근:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8443:443 --address=0.0.0.0"
echo "  → https://localhost:8443"
echo "============================================="
