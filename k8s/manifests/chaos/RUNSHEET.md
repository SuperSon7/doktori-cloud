# FI 실험 런시트

실행 준비 완료 상태 (2026-03-23 확인). 이 문서 순서대로 진행.

## 사전 확인 (매 실험 전)

```bash
kubectl get pods -n prod -o wide          # 전부 Running
kubectl get hpa -n prod                   # TARGETS에 CPU % 표시
kubectl get pods -n chaos-testing         # Chaos Mesh Running
```

Grafana 열어두기: http-red + jvm-api + container-resources

---

## Phase 1: Baseline (10분)

부하 생성기에서:
```bash
./run-distributed.sh smoke --prom --pull
```
Grafana 스크린샷 저장: API P50/P95/P99, 5xx율, HikariCP, HPA replicas

---

## Phase 2: 부하 테스트 (2시간)

```bash
# 순서대로 실행
./run-distributed.sh load --prom          # 300 VU, 16분
./run-distributed.sh stress --prom        # 1500 VU, 13분
./run-distributed.sh spike --prom         # 5분
./run-distributed.sh soak --prom          # 1시간 (시간 여유 있을 때)
```

---

## Phase 3: 장애 주입 (FI)

master 노드에서 실행. **한 번에 하나만.**

```bash
cd /tmp/cloud-repo/k8s/manifests/chaos
```

### 컴포넌트 단위 (안전한 것부터)

#### FI-15A: CoreDNS 1개 kill (HA 검증) — 60초
```bash
kubectl apply -f fi-15-coredns-kill.yaml
# 관측: kubectl get pods -n kube-system -l k8s-app=kube-dns -w
# 확인: kubectl exec <api-pod> -n prod -- nslookup kubernetes.default
# 60초 후 자동 해제
```
- [ ] CoreDNS 1개 죽어도 DNS 정상 → HA 확인
- [ ] 스크린샷 저장

#### FI-16: metrics-server kill — 60초
```bash
kubectl apply -f fi-16-metrics-server-kill.yaml
# 관측: kubectl get hpa -n prod -w  (TARGETS → <unknown>)
# 60초 후 자동 해제 → TARGETS 복구 확인
```
- [ ] HPA TARGETS `<unknown>` 확인
- [ ] 서비스 영향 없음 확인
- [ ] 복구 후 TARGETS 정상 확인

#### FI-14: Alloy (모니터링) kill — 30초
```bash
kubectl apply -f fi-14-monitoring-kill.yaml
# 관측: Grafana 메트릭 끊김 확인 → Alloy 재시작 후 복원
```
- [ ] 서비스 SLO 영향 없음
- [ ] Grafana 메트릭 갭 확인 + 복원 확인

#### FI-1: API Pod 50% kill — 30초
```bash
kubectl apply -f fi-1-api-pod-kill.yaml
# 관측: kubectl get pods -n prod -w + http-red 5xx
```
- [ ] 5xx 구간 < 30초
- [ ] Pod 재시작 < 60초
- [ ] SLO-1 유지

#### FI-2: Chat Pod kill — 30초
```bash
kubectl apply -f fi-2-chat-pod-kill.yaml
# 관측: Chat probe + kubectl get pods -n prod -w
```
- [ ] SLO-3 3분 이내 복구
- [ ] Chat probe 정상 복귀

#### FI-4: CPU Stress (HPA 트리거) — 5분
```bash
kubectl apply -f fi-4-cpu-stress.yaml
# 관측: kubectl get hpa -n prod -w  (replica 변화)
```
- [ ] HPA 2→3~4 스케일아웃 확인
- [ ] 스케일아웃 소요 시간 기록
- [ ] 해제 후 스케일다운 확인 (5분 후)

#### FI-3: DB 지연 200ms — 5분
```bash
kubectl apply -f fi-3-db-latency.yaml
# 관측: jvm-api HikariCP pending, http-red P95
```
- [ ] HikariCP pending = 0
- [ ] API P95 < 1,000ms
- [ ] 5xx 0건

#### FI-9: Gateway kill — 30초
```bash
kubectl apply -f fi-9-gateway-kill.yaml
# 관측: 외부에서 curl https://api.doktori.kr/api/health
```
- [ ] Gateway replica 1개 → **SPOF 확인 (서비스 중단 예상)**
- [ ] 재시작 시간 기록
- [ ] 결론: Gateway replica 증설 필요 여부 판단

#### FI-17: Calico kill — 30초
```bash
kubectl apply -f fi-17-calico-kill.yaml
# 관측: kubectl get pods -n calico-system -w
```
- [ ] 기존 Pod 통신 유지
- [ ] Calico 재시작 < 30초

#### FI-11: API↔Chat 네트워크 파티션 — 5분
```bash
kubectl apply -f fi-11-network-partition.yaml
# 관측: http-red (API), Chat probe (Chat) — 양쪽 독립 동작 확인
```
- [ ] API SLO-1 유지
- [ ] Chat SLO-3 유지

### 부하 중 실행 (k6 먼저 실행 후)

#### FI-7: Rolling Update 무중단 — k6 부하 중
```bash
# 터미널 1: ./run-distributed.sh load --prom
# 터미널 2:
chmod +x fi-7-rolling-update.sh
./fi-7-rolling-update.sh <현재와-같은-image-tag>
```
- [ ] 배포 중 5xx = 0건
- [ ] k6 errors rate = 0%

#### FI-8: Graceful Shutdown — k6 부하 중
```bash
# 터미널 1: ./run-distributed.sh load --prom
# 터미널 2:
chmod +x fi-8-graceful-shutdown.sh
./fi-8-graceful-shutdown.sh
```
- [ ] 삭제 중 5xx = 0건

### k8s 위험 실험 (마지막에)

#### FI-15B: CoreDNS 전체 kill — 30초
```bash
kubectl apply -f fi-15-coredns-full-kill.yaml
# ⚠️ 전체 DNS 장애! 복구 준비:
# kubectl rollout restart deployment/coredns -n kube-system
```
- [ ] DNS 장애 범위 확인
- [ ] CoreDNS 자동 재시작 시간 기록

#### FI-5: 워커 노드 drain
```bash
# 노드 확인
kubectl get pods -n prod -o wide
# 가장 Pod가 적은 노드 선택
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=120s
# 관측: kubectl get pods -n prod -o wide -w
# 복구: kubectl uncordon <node-name>
```
- [ ] Pod 재스케줄링 < 2분
- [ ] SLO 유지
- [ ] PDB 준수

#### FI-12: AZ 장애
```bash
chmod +x fi-12-az-failure.sh
./fi-12-az-failure.sh drain 2a    # 또는 해당 AZ suffix
# 복구: ./fi-12-az-failure.sh recover 2a
```
- [ ] 다른 AZ에서 Pod Running
- [ ] SLO 유지

---

## Phase 4: 복합 검증

#### FI-10: 연쇄 장애 (k6 stress + DB 500ms)
```bash
# 터미널 1: ./run-distributed.sh stress --prom
# 터미널 2:
chmod +x fi-10-cascading-failure.sh
./fi-10-cascading-failure.sh
```
- [ ] HikariCP pending 관찰
- [ ] HPA 스케일아웃이 악화/안정화?
- [ ] 5xx rate 최대치 기록

#### FI-13: Game Day (30분)
```bash
# 터미널 1: ./run-distributed.sh load --prom  (35분 이상)
# 터미널 2:
chmod +x fi-13-gameday.sh
./fi-13-gameday.sh
```
- [ ] 전체 30분 SLO-1 > 99.0%
- [ ] SLO-3 유지
- [ ] k6 에러율 < 5%
- [ ] 각 Round별 Grafana 스크린샷

---

## 비상 중단

```bash
# 방법 1
./run-experiment.sh stop-all

# 방법 2
kubectl delete podchaos,networkchaos,stresschaos,iochaos,httpchaos,dnschaos --all -n chaos-testing

# 노드 drain 복구
kubectl uncordon <node-name>
```

---

## 스킵 시나리오

| ID | 사유 |
|----|------|
| FI-6 (RabbitMQ) | k8s 외부에서 운영 — Chaos Mesh 대상 아님 |

---

## 결과 기록

각 실험 완료 후:

```markdown
## [FI-X] 결과
- 시각: HH:MM
- 결과: ✅ / ❌ / ⚠️
- 관측값:
  | 지표 | 기대 | 실측 |
  |------|------|------|
- Grafana 스크린샷: (링크)
- 발견:
- 후속:
```