#!/usr/bin/env bash
# =============================================================================
# ArgoCD 초기 설정 자동화
# install-argocd.sh 실행 후 이 스크립트로 [A]~[D] 자동 구성
#
# 사용법: master 노드에서 실행
#   chmod +x setup-argocd.sh
#   ./setup-argocd.sh [--skip-etcd] [--skip-kubelet]
#
# 옵션:
#   --skip-etcd     etcd 암호화 건너뜀
#   --skip-kubelet  kubelet 보안 설정 건너뜀
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

SKIP_ETCD=false
SKIP_KUBELET=false

for arg in "$@"; do
  case "$arg" in
    --skip-etcd)    SKIP_ETCD=true ;;
    --skip-kubelet) SKIP_KUBELET=true ;;
  esac
done

echo "============================================="
echo " ArgoCD 초기 설정"
echo "============================================="

# -----------------------------------------------------------------------------
# [A] Git 저장소 연결
# -----------------------------------------------------------------------------
echo ""
echo "[A] Git 저장소 연결..."

# config.env에서 값이 있으면 사용, 없으면 프롬프트
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

  # Application manifest에 repo URL 주입 후 배포
  echo "  → ArgoCD Application 배포..."
  for APP_FILE in "${SCRIPT_DIR}/manifests/argocd/application-"*.yaml; do
    if [ -f "$APP_FILE" ]; then
      sed "s|__GIT_REPO_URL__|${REPO_URL}|g" "$APP_FILE" | kubectl apply -f -
      echo "    $(basename "$APP_FILE") 적용됨"
    fi
  done
fi

# -----------------------------------------------------------------------------
# [B] etcd 암호화 (Secret 보호)
# -----------------------------------------------------------------------------
echo ""
if [ "$SKIP_ETCD" = true ]; then
  echo "[B] etcd 암호화 — 건너뜀 (--skip-etcd)"
else
  echo "[B] etcd 암호화 설정..."

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

    # kube-apiserver manifest에 encryption-provider-config 추가
    APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
    if [ -f "$APISERVER_MANIFEST" ]; then
      if grep -q "encryption-provider-config" "$APISERVER_MANIFEST"; then
        echo "  → kube-apiserver에 이미 encryption 설정 있음"
      else
        echo "  → kube-apiserver manifest 패치..."
        # 임시 파일로 작업
        TEMP_FILE=$(mktemp)
        cp "$APISERVER_MANIFEST" "$TEMP_FILE"

        # --encryption-provider-config 플래그 추가
        sudo sed -i '/- --tls-private-key-file/a\    - --encryption-provider-config=\/etc\/kubernetes\/encryption-config.yaml' "$APISERVER_MANIFEST"

        # hostPath volume + volumeMount 추가 (encryption-config)
        if ! grep -q "encryption-config" "$APISERVER_MANIFEST"; then
          # volumeMount 추가 (containers.volumeMounts 마지막에)
          sudo sed -i '/name: k8s-certs/i\    - mountPath: \/etc\/kubernetes\/encryption-config.yaml\n      name: encryption-config\n      readOnly: true' "$APISERVER_MANIFEST"
          # volume 추가 (volumes 마지막에)
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

# -----------------------------------------------------------------------------
# [C] kubelet 보안 설정
# -----------------------------------------------------------------------------
echo ""
if [ "$SKIP_KUBELET" = true ]; then
  echo "[C] kubelet 보안 — 건너뜀 (--skip-kubelet)"
else
  echo "[C] kubelet 보안 설정..."

  KUBELET_CONFIG="/var/lib/kubelet/config.yaml"

  if [ ! -f "$KUBELET_CONFIG" ]; then
    echo "  [WARN] ${KUBELET_CONFIG} 없음. 건너뜁니다."
  else
    CHANGED=false

    # anonymous auth 비활성화
    if grep -q "enabled: true" <(grep -A1 "anonymous:" "$KUBELET_CONFIG"); then
      sudo sed -i '/anonymous:/,/enabled:/{s/enabled: true/enabled: false/}' "$KUBELET_CONFIG"
      CHANGED=true
      echo "  → anonymous auth 비활성화"
    else
      echo "  → anonymous auth 이미 비활성화됨"
    fi

    # readOnlyPort 비활성화
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

# -----------------------------------------------------------------------------
# [D] ArgoCD 비밀번호 변경
# -----------------------------------------------------------------------------
echo ""
echo "[D] ArgoCD 비밀번호 변경..."

read -rsp "  새 ArgoCD admin 비밀번호 (빈 값이면 건너뜀): " NEW_PASSWORD
echo ""

if [ -z "$NEW_PASSWORD" ]; then
  echo "  → 건너뜀. 초기 비밀번호 유지."
else
  # bcrypt 해시 생성 (htpasswd 또는 python 사용)
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

    # 초기 비밀번호 Secret 삭제
    kubectl delete secret argocd-initial-admin-secret -n argocd 2>/dev/null || true
    echo "  → 초기 비밀번호 Secret 삭제됨"
  fi
fi

# -----------------------------------------------------------------------------
# 결과 확인
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " ArgoCD 설정 완료"
echo "============================================="
echo ""
echo "--- ArgoCD Applications ---"
kubectl get applications -n argocd 2>/dev/null || echo "  아직 Application 없음"
echo ""
echo "--- ArgoCD Pods ---"
kubectl get pods -n argocd
echo ""
echo "접근:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8443:443 --address=0.0.0.0"
echo "  → https://localhost:8443"
echo "============================================="
