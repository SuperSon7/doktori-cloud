# NGF 업그레이드: v1.6.2 → v2.4.2

> 생성: 2026-03-22
> 상태: 준비 중 (다음 부트스트랩에서 적용)

---

## 왜 업그레이드하는가

1. **upstream keepAlive 미지원** — v1alpha1에서는 keepAlive 설정 불가. 매 요청마다 새 TCP 연결 → NodePort 커넥션 폭발 (5xx 17만건의 원인)
2. **버전 격차** — 현재 v1.6.2, 최신 v2.4.2. 보안 패치 및 기능 개선 누적
3. **v2.x 신기능** — RateLimitPolicy, UpstreamSettingsPolicy, 멀티 Gateway, control/data plane 분리

---

## 아키텍처 변경 (v1 → v2)

```
v1.x:
  Helm install → 단일 Pod (control + data) + Service (NodePort)

v2.x:
  Helm install → control plane Pod (nginx-gateway ns)
                    ↓ Gateway 리소스 감지
                 → data plane Pod + Service 동적 프로비저닝 (Gateway가 있는 ns)
```

- control plane과 data plane이 별도 Deployment
- Gateway 리소스를 만들면 control plane이 자동으로 NGINX data plane을 프로비저닝
- control ↔ data 간 gRPC + TLS 통신 (cert-generator Job이 인증서 자동 생성)

---

## 변경 대상 파일

### 1. cluster-init.sh — Helm install 명령 변경

```bash
# AS-IS (v1.x)
helm install nginx-gw oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version "1.6.2" \
  --namespace nginx-gateway \
  --create-namespace \
  --set service.type=NodePort \
  --set "service.ports[0].port=80,service.ports[0].nodePort=30080,..." \
  --set "service.ports[1].port=443,service.ports[1].nodePort=30443,..."

# TO-BE (v2.x)
helm install nginx-gw oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version "2.4.2" \
  --namespace nginx-gateway \
  --create-namespace \
  --set nginx.service.type=NodePort \
  --set "nginx.service.nodePorts[0].port=30080,nginx.service.nodePorts[0].listenerPort=80" \
  --set "nginx.service.nodePorts[1].port=30443,nginx.service.nodePorts[1].listenerPort=443"
```

변경 포인트:
- `service.type` → `nginx.service.type`
- `service.ports[]` → `nginx.service.nodePorts[]` (구조 완전 변경)
- `service.ports[].nodePort` → `nginx.service.nodePorts[].port`
- `service.ports[].port` → `nginx.service.nodePorts[].listenerPort`

### 2. config.env

```bash
# AS-IS
NGF_VERSION="1.6.2"

# TO-BE
NGF_VERSION="2.4.2"
```

### 3. nginx-proxy.yaml — v1alpha2 + namespace-scoped

```yaml
# AS-IS
apiVersion: gateway.nginx.org/v1alpha1
kind: NginxProxy
metadata:
  name: doktori-proxy-config
spec:
  rewriteClientIP:
    mode: XForwardedFor
    setIPRecursively: false
    trustedAddresses:
      - type: CIDR
        value: "10.0.0.0/8"
  # upstream.keepAlive는 v1alpha2 전용 — 주석 처리

# TO-BE
apiVersion: gateway.nginx.org/v1alpha2
kind: NginxProxy
metadata:
  name: doktori-proxy-config
  namespace: nginx-gateway          # 필수 — v1alpha2는 namespace-scoped
spec:
  rewriteClientIP:
    mode: XForwardedFor
    setIPRecursively: false
    trustedAddresses:
      - type: CIDR
        value: "10.0.0.0/8"
  # keepAlive는 UpstreamSettingsPolicy로 이동됨 (별도 리소스)
```

### 4. gateway-class.yaml — Helm 충돌 해결

**문제**: v2.x Helm 차트가 `name: nginx` GatewayClass를 자동 생성. 우리 매니페스트도 같은 이름으로 생성 → 충돌.

**선택지**:

| 방법 | 장점 | 단점 |
|------|------|------|
| A. 우리 gateway-class.yaml 삭제, Helm이 GatewayClass 관리 | 단순함 | parametersRef를 Helm values로 넘겨야 함 |
| B. Helm에서 GatewayClass 생성 비활성화, 우리가 관리 | 기존 방식 유지 | Helm values 확인 필요 |

**권장: A** — Helm이 GatewayClass를 만들게 하고, NginxProxy는 GatewayClass의 `parametersRef`가 아닌 **Gateway의 `infrastructure.parametersRef`**로 연결.

또는 Helm values에서 parametersRef 설정이 가능한지 확인 필요:
```bash
helm show values oci://ghcr.io/nginx/charts/nginx-gateway-fabric --version 2.4.2 | grep -A5 parametersRef
```

**B를 선택할 경우** gateway-class.yaml 유지:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: gateway.nginx.org/nginx-gateway-controller
  parametersRef:
    group: gateway.nginx.org
    kind: NginxProxy
    name: doktori-proxy-config
    namespace: nginx-gateway    # v2.x에서 namespace 추가 필요할 수 있음
```

### 5. 신규: upstream-settings.yaml — keepAlive 설정

v2.x에서 keepAlive는 NginxProxy가 아닌 **UpstreamSettingsPolicy** 리소스:

```yaml
# k8s/manifests/workloads/upstream-settings.yaml
apiVersion: gateway.nginx.org/v1alpha1
kind: UpstreamSettingsPolicy
metadata:
  name: api-upstream-settings
  namespace: prod
spec:
  targetRefs:
    - group: core
      kind: Service
      name: api-svc
  keepAlive:
    connections: 64
    requests: 1000
    time: "1h"
    timeout: "60s"
---
apiVersion: gateway.nginx.org/v1alpha1
kind: UpstreamSettingsPolicy
metadata:
  name: chat-upstream-settings
  namespace: prod
spec:
  targetRefs:
    - group: core
      kind: Service
      name: chat-svc
  keepAlive:
    connections: 64
    requests: 1000
    time: "1h"
    timeout: "60s"
```

### 6. gateway.yaml, httproutes.yaml — 변경 없음

Gateway API v1은 v2.4.2에서도 호환. 수정 불필요.

---

## 위험 체크리스트

### 🔴 높은 위험 (트래픽 단절 가능)

| # | 항목 | 설명 | 확인 방법 |
|---|------|------|----------|
| 1 | **NodePort 번호 유지** | NLB target group이 30080/30443을 바라봄. v2.x에서 다른 NodePort가 할당되면 트래픽 끊김 | 부트스트랩 후 `kubectl get svc -A \| grep nginx`로 NodePort 확인 |
| 2 | **NginxProxy namespace** | v1alpha2는 namespace-scoped. nginx-gateway에 생성되어야 control plane이 인식 | `kubectl get nginxproxy -n nginx-gateway` |
| 3 | **GatewayClass 충돌** | Helm + ArgoCD 양쪽에서 같은 GatewayClass를 관리하면 무한 덮어쓰기 | 소유자를 하나로 통일 |
| 4 | **data plane Service 위치** | v2.x에서 Service가 Gateway namespace(prod)에 생성될 수 있음. NLB가 nginx-gateway ns의 Service를 바라보고 있다면 불일치 | 부트스트랩 후 Service가 어디에 생성되는지 확인 |

### 🟡 중간 위험

| # | 항목 | 설명 |
|---|------|------|
| 5 | **UpstreamSettingsPolicy CRD** | v2.4.2 CRD에 포함되는지 확인. 없으면 keepAlive 설정 불가 |
| 6 | **cert-generator Job** | control↔data plane TLS 인증서를 Job이 생성. Job 실패 시 data plane 프로비저닝 안 됨 |
| 7 | **ArgoCD가 nginx-proxy.yaml 배포 시 namespace** | doktori-workloads Application dest=prod인데, nginx-proxy.yaml에 namespace: nginx-gateway 명시하면 괜찮은지 |

### 🟢 낮은 위험

| # | 항목 | 설명 |
|---|------|------|
| 8 | **Gateway API CRD 버전** | 현재 v1.4.1, v2.4.2도 v1.4.1 요구 → 호환 |
| 9 | **Kubernetes 버전** | v1.31, v2.4.2은 1.25+ 요구 → 호환 |
| 10 | **SnippetsFilter 플래그명** | `snippetsFilters.enable` → `snippets.enable` (v2.4 deprecated). 현재 주석이라 영향 없음 |
| 11 | **htroutes.yaml 주석의 rate-limit** | 나중에 활성화 시 v2.4 RateLimitPolicy 사용 가능 (SnippetsFilter 대신) |

---

## 부트스트랩 순서 (v2.4.2 기준)

```
Phase 0: Terraform apply
Phase 1: kubeadm init/join
Phase 2: Calico CNI (Helm standalone)
Phase 3: Gateway API CRD 설치 (v1.4.1)
Phase 4: NGF v2.4.2 (Helm standalone)
         → control plane Pod 시작
         → cert-generator Job이 TLS 인증서 생성
Phase 5: ECR credential provider (Ansible)
Phase 6: ArgoCD (Helm standalone) + root-app
Phase 7: ArgoCD가 자동 배포:
         → NginxProxy (v1alpha2, nginx-gateway ns)
         → GatewayClass (Helm 충돌 해결 방식에 따라)
         → Gateway (prod ns) → data plane 프로비저닝 트리거
         → HTTPRoutes
         → UpstreamSettingsPolicy (keepAlive)
         → 워크로드, HPA, NetworkPolicy, Alloy 등
```

**Phase 4 후 확인**:
```bash
kubectl get pods -n nginx-gateway               # control plane Running
kubectl get job -n nginx-gateway                 # cert-generator Completed
```

**Phase 7 후 확인**:
```bash
kubectl get gateway -n prod                       # Accepted + Programmed
kubectl get svc -A | grep nginx                   # NodePort 30080/30443 확인
kubectl get nginxproxy -n nginx-gateway            # doktori-proxy-config 존재
kubectl get upstreamsettingspolicy -n prod          # keepAlive 설정 확인
curl http://<NLB>:30080/api/health                 # 트래픽 정상
```

---

## 롤백 계획

신규 부트스트랩이므로 롤백 = cluster-init.sh에서 NGF_VERSION을 1.6.2로 되돌리고 재실행.

```bash
# config.env
NGF_VERSION="1.6.2"

# nginx-proxy.yaml을 v1alpha1로 복원
# gateway-class.yaml 복원
# upstream-settings.yaml 제거
# cluster-init.sh의 Helm values를 v1.x 형식으로 복원
```

---

## 참고 자료

- NGF v2.0.0 Breaking Changes: control/data plane 분리 (https://github.com/nginx/nginx-gateway-fabric/releases/tag/v2.0.0)
- NginxProxy v1alpha2 API: namespace-scoped, keepAlive 제거
- UpstreamSettingsPolicy: keepAlive를 서비스별로 설정
- Helm values 구조: `service.*` → `nginx.service.*`
- NodePort 설정: `nginx.service.nodePorts[].port` + `listenerPort`