#!/usr/bin/env bash
# =============================================================================
# 워크로드 배포 — ECR 인증 + Deployments + Services + Gateway + HTTPRoutes
#
# 사용법: master 노드에서 실행
#   ./deploy-workloads.sh
#
# cluster-init.sh + worker join 완료 후 사용
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

MANIFESTS_DIR="${SCRIPT_DIR}/manifests/workloads"

echo "============================================="
echo " 워크로드 배포"
echo " Namespace: ${NAMESPACE}"
echo " ECR: ${ECR_REGISTRY}"
echo "============================================="

# -----------------------------------------------------------------------------
# 0. 사용자 입력 (보안 값)
# -----------------------------------------------------------------------------
read -rp "api  이미지 태그 (예: latest): " API_IMAGE_TAG
read -rp "chat 이미지 태그 (예: latest): " CHAT_IMAGE_TAG
read -rp "SPRING_PROFILES_ACTIVE (예: prod, staging): " SPRING_PROFILE

echo ""

# -----------------------------------------------------------------------------
# 1. Namespace
# -----------------------------------------------------------------------------
echo "[1/7] Namespace..."
kubectl create namespace "${NAMESPACE}" 2>/dev/null || echo "  → 이미 존재"

# -----------------------------------------------------------------------------
# 2. ECR 인증 Secret
# -----------------------------------------------------------------------------
echo "[2/7] ECR imagePullSecret..."

ECR_TOKEN=$(aws ecr get-login-password --region "${AWS_REGION}")
kubectl delete secret ecr-credentials -n "${NAMESPACE}" --ignore-not-found
kubectl create secret docker-registry ecr-credentials \
  --namespace="${NAMESPACE}" \
  --docker-server="${ECR_REGISTRY}" \
  --docker-username=AWS \
  --docker-password="${ECR_TOKEN}"

echo "  → ecr-credentials 생성 완료 (12시간 유효)"

# -----------------------------------------------------------------------------
# 3. ECR 토큰 자동 갱신 CronJob + RBAC
# -----------------------------------------------------------------------------
echo "[3/7] ECR 토큰 갱신 CronJob..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ecr-token-refresher
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ecr-secret-manager
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ecr-token-refresher-binding
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ecr-token-refresher
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ecr-secret-manager
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ecr-token-refresh
  namespace: ${NAMESPACE}
spec:
  schedule: "0 */10 * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: ecr-token-refresher
          containers:
            - name: refresh
              image: amazon/aws-cli:latest
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  ECR_TOKEN=\$(aws ecr get-login-password --region ${AWS_REGION})
                  TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
                  API_SERVER="https://kubernetes.default.svc"
                  SECRET_NAME="ecr-credentials"
                  NS="${NAMESPACE}"

                  # Delete existing secret
                  curl -s -k -X DELETE "\${API_SERVER}/api/v1/namespaces/\${NS}/secrets/\${SECRET_NAME}" \
                    -H "Authorization: Bearer \${TOKEN}" || true

                  # Create docker-registry secret
                  DOCKER_CONFIG=\$(echo -n "{\"auths\":{\"${ECR_REGISTRY}\":{\"username\":\"AWS\",\"password\":\"\${ECR_TOKEN}\"}}}" | base64 -w 0)
                  curl -s -k -X POST "\${API_SERVER}/api/v1/namespaces/\${NS}/secrets" \
                    -H "Authorization: Bearer \${TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d "{
                      \"apiVersion\": \"v1\",
                      \"kind\": \"Secret\",
                      \"metadata\": {\"name\": \"\${SECRET_NAME}\", \"namespace\": \"\${NS}\"},
                      \"type\": \"kubernetes.io/dockerconfigjson\",
                      \"data\": {\".dockerconfigjson\": \"\${DOCKER_CONFIG}\"}
                    }"
                  echo "ECR token refreshed"
          restartPolicy: OnFailure
EOF

echo "  → CronJob 생성 (10시간 간격)"

# -----------------------------------------------------------------------------
# 4. api Deployment + Service + PDB (Flyway 마이그레이션 — chat보다 먼저)
# -----------------------------------------------------------------------------
echo "[4/7] api 서비스 배포 (Flyway 선행)..."

# Firebase Secret — SSM에서 자동 가져오기, 실패 시 수동 안내
if ! kubectl get secret firebase-credentials -n "${NAMESPACE}" &>/dev/null; then
  echo "  Firebase Secret 없음 — SSM에서 가져오는 중..."
  SSM_FIREBASE_KEY="/${PROJECT_NAME}/${NAMESPACE}/FIREBASE_SERVICE_ACCOUNT"

  if FIREBASE_JSON=$(aws ssm get-parameter \
    --name "${SSM_FIREBASE_KEY}" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "${AWS_REGION}" 2>/dev/null); then

    echo "${FIREBASE_JSON}" > /tmp/firebase-service-account.json
    kubectl create secret generic firebase-credentials \
      --namespace="${NAMESPACE}" \
      --from-file=firebase-service-account.json=/tmp/firebase-service-account.json
    rm -f /tmp/firebase-service-account.json
    echo "  → Firebase Secret 생성 완료 (SSM)"
  else
    echo ""
    echo "  ⚠ SSM에서 Firebase 인증 정보를 찾을 수 없습니다 (${SSM_FIREBASE_KEY})"
    echo "    수동 생성:"
    echo "      kubectl create secret generic firebase-credentials \\"
    echo "        --namespace=${NAMESPACE} \\"
    echo "        --from-file=firebase-service-account.json=<파일경로>"
    echo ""
    read -rp "  Firebase Secret 없이 계속할까요? FCM 푸시가 안 됩니다. (y/N): " SKIP_FIREBASE
    if [[ "${SKIP_FIREBASE}" != "y" && "${SKIP_FIREBASE}" != "Y" ]]; then
      echo "  → Firebase Secret 생성 후 다시 실행하세요."
      exit 1
    fi
  fi
fi

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: doktori
      component: api
  template:
    metadata:
      labels:
        app: doktori
        component: api
    spec:
      imagePullSecrets:
        - name: ecr-credentials
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: doktori
              component: api
      containers:
        - name: api
          image: ${ECR_REGISTRY}/doktori/prod-backend-api:${API_IMAGE_TAG}
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "300m"
              memory: "512Mi"
            limits:
              memory: "1280Mi"
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: "${SPRING_PROFILE}"
            - name: FIREBASE_CREDENTIALS_PATH
              value: "file:/app/secrets/firebase-service-account.json"
          volumeMounts:
            - name: firebase-cred
              mountPath: /app/secrets
              readOnly: true
          lifecycle:
            preStop:
              exec:
                command: ["sleep", "15"]
      volumes:
        - name: firebase-cred
          secret:
            secretName: firebase-credentials
            optional: true
---
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: ${NAMESPACE}
spec:
  selector:
    app: doktori
    component: api
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-pdb
  namespace: ${NAMESPACE}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: doktori
      component: api
EOF

echo "  → api Deployment + Service + PDB"

# -----------------------------------------------------------------------------
# 5. chat Deployment + Service + PDB (api Flyway 완료 후)
# -----------------------------------------------------------------------------
echo "[5/7] chat 서비스 배포..."

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: doktori
      component: chat
  template:
    metadata:
      labels:
        app: doktori
        component: chat
    spec:
      imagePullSecrets:
        - name: ecr-credentials
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: doktori
              component: chat
      containers:
        - name: chat
          image: ${ECR_REGISTRY}/doktori/prod-backend-chat:${CHAT_IMAGE_TAG}
          ports:
            - containerPort: 8081
          resources:
            requests:
              cpu: "300m"
              memory: "512Mi"
            limits:
              memory: "1536Mi"
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: "${SPRING_PROFILE}"
          lifecycle:
            preStop:
              exec:
                command: ["sleep", "15"]
---
apiVersion: v1
kind: Service
metadata:
  name: chat-svc
  namespace: ${NAMESPACE}
spec:
  selector:
    app: doktori
    component: chat
  ports:
    - port: 8081
      targetPort: 8081
  type: ClusterIP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: chat-pdb
  namespace: ${NAMESPACE}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: doktori
      component: chat
EOF

echo "  → chat Deployment + Service + PDB"

# -----------------------------------------------------------------------------
# 6. Gateway 리소스
# -----------------------------------------------------------------------------
echo "[6/7] Gateway..."

cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: doktori-gateway
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF

echo "  → doktori-gateway"

# -----------------------------------------------------------------------------
# 7. HTTPRoutes
# -----------------------------------------------------------------------------
echo "[7/7] HTTPRoutes..."

cat <<EOF | kubectl apply -f -
# WebSocket — /ws/chat → rewrite /api/ws
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: chat-ws-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: doktori-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /ws/chat
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /api/ws
      timeouts:
        backendRequest: "1h"
      backendRefs:
        - name: chat-svc
          port: 8081
---
# chat REST API
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: chat-api-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: doktori-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/chat/
      timeouts:
        backendRequest: "1h"
      backendRefs:
        - name: chat-svc
          port: 8081
    - matches:
        - path:
            type: PathPrefix
            value: /api/chat-rooms/
      timeouts:
        backendRequest: "75s"
      backendRefs:
        - name: chat-svc
          port: 8081
---
# api REST API (catch-all /api/)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: doktori-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/
      timeouts:
        backendRequest: "30s"
      backendRefs:
        - name: api-svc
          port: 8080
EOF

echo "  → WebSocket + chat API + api routes"

# -----------------------------------------------------------------------------
# 검증
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " 배포 완료 — 검증"
echo "============================================="

echo ""
echo "--- Pods ---"
kubectl get pods -n "${NAMESPACE}" -o wide

echo ""
echo "--- Services ---"
kubectl get svc -n "${NAMESPACE}"

echo ""
echo "--- Gateway ---"
kubectl get gateway -n "${NAMESPACE}"

echo ""
echo "--- HTTPRoutes ---"
kubectl get httproute -n "${NAMESPACE}"

echo ""
echo "============================================="
echo " NOTE: api → chat 순서로 배포됨 (Flyway 선행)"
echo "   DDL 충돌 시: kubectl scale deploy/chat -n ${NAMESPACE} --replicas=0"
echo "   → api 재시작 → chat replicas=2 복원"
echo ""
echo " 다음 단계:"
echo "   1. Pod READY 확인: kubectl get pods -n ${NAMESPACE} -w"
echo "   2. NLB 경유 테스트: curl http://<NLB_DNS>/api/health"
echo "   3. Observability: ./install-observability.sh"
echo "   4. ArgoCD + 보안: ./install-argocd.sh"
echo "============================================="