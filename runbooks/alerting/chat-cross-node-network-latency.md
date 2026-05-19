# Chat Cross-node Network Latency

| 항목 | 값 |
|------|-----|
| Severity | Warning |
| 대상 | Chat WebSocket / cross-node Pod 통신 |
| 증상 | connect duration 증가, heartbeat 지연, 간헐 disconnect |
| 우선 가설 | EndpointSlice, NetworkPolicy, HPA 문제를 제거한 뒤 Calico VXLAN MTU 정합성 확인 |

---

## 1. 즉시 확인

```bash
kubectl get pod -n prod -o wide
kubectl get pod -n prod -l app.kubernetes.io/name=doktori-gateway-nginx -o wide
kubectl get pod -n prod -l app=doktori,component=chat -o wide

kubectl get svc,endpointslice -n prod
kubectl describe svc chat-svc -n prod
kubectl get endpointslice -n prod -l kubernetes.io/service-name=chat-svc -o yaml

kubectl top pod -n prod
kubectl get hpa -n prod
kubectl describe hpa chat-hpa -n prod
```

확인 포인트:

- Gateway Pod 와 chat Pod 가 어떤 노드에 올라가 있는지
- `chat-svc` endpoint 누락이 없는지
- restart, OOM, probe failure 가 없는지

## 2. 빠른 분기

| 증상 | 우선 확인 | 해석 |
|------|------|------|
| 모든 연결이 바로 실패 | Service / EndpointSlice / NetworkPolicy | 정책 또는 라우팅 문제 가능성 큼 |
| same-node 도 같이 느림 | 앱 처리 지연 / Gateway / 리소스 | MTU 단독 원인 가능성 낮음 |
| cross-node 에서만 악화 | Calico VXLAN / MTU / underlay | 네트워크 계층 우선 |
| 큰 payload 에서만 불안정 | `ping -M do`, `iperf3`, retransmission | MTU mismatch 의심 |

## 3. 네트워크 확인

```bash
kubectl describe networkpolicy allow-ngf-to-chat -n prod
kubectl describe networkpolicy allow-ngf-dataplane-egress -n prod
kubectl describe networkpolicy allow-dns-egress -n prod

kubectl get installation default -o yaml
kubectl get ippool -A -o yaml
```

노드 접근 가능 시:

```bash
ip link show
ip link show vxlan.calico
ip route
sudo tcpdump -ni <underlay-if> udp port 4789
```

Pod 내부:

```bash
kubectl exec -n prod <chat-pod> -- ip link show
kubectl exec -n prod <chat-pod> -- ip route
kubectl exec -n prod netshoot-a -- ping -M do -s 1422 <peer-pod-ip>
kubectl exec -n prod netshoot-a -- ss -ti
kubectl exec -n prod netshoot-a -- nstat -az | grep -E 'TcpRetrans|TcpTimeout|TcpExtTCPSynRetrans'
```

## 4. 대응

| 원인 | 조치 |
|------|------|
| EndpointSlice 누락 | selector / label 확인 후 배포 수정 |
| NetworkPolicy 차단 | `allow-ngf-to-chat`, egress 정책 수정 |
| HPA / 리소스 병목 | 스케일 / JVM / app 병목 점검 |
| VXLAN MTU 불일치 | Calico `spec.calicoNetwork.mtu`, `vxlan.calico`, Pod veth, underlay NIC MTU 정합성 검토 |

## 5. 복구 확인

- [ ] same-node / cross-node 조건 차이가 줄었는지 확인
- [ ] `ws_connect_duration` p95/p99 개선
- [ ] `ws_errors`, `ws_connect_failed` 감소
- [ ] `iperf3` retransmits 감소
- [ ] `ping -M do` 임계값이 기대 범위로 정리됨
- [ ] UDP 4789 는 보이되, disconnect 는 줄어듦

## 6. 에스컬레이션

- 15분 이상 cross-node 증상이 지속되면 인프라 담당자 호출
- MTU 조정이 필요하면 staging 에서 먼저 재현 후 변경
- SG/NACL 에서 UDP 4789 차단 흔적이 있으면 네트워크 담당과 함께 확인

