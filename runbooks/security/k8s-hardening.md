# K8s cluster hardening

Last updated: 2026-03-17
Author: jbdev

etcd 암호화 + kubelet 보안 강화. 클러스터 부트스트랩 후 적용.

## Before you begin

- K8s 클러스터 Running (Master 3 + Worker N)
- 마스터 노드 sudo 권한 (SSM 접속)
- 트래픽 적은 시간대 권장 (apiserver 재시작 발생)

## Step 1: etcd encryption at rest (master only)

1. 암호화 키를 생성하고 EncryptionConfiguration을 작성한다.

   ```bash
   ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

   sudo tee /etc/kubernetes/encryption-config.yaml > /dev/null <<EOF
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
   EOF

   sudo chmod 600 /etc/kubernetes/encryption-config.yaml
   ```

   > **Note:** `ENCRYPTION_KEY`는 안전한 곳에 백업해둘 것. 분실 시 암호화된 Secret 복구 불가.

2. kube-apiserver manifest를 패치한다.

   ```bash
   sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

   **command 섹션**에 플래그 추가 (`--tls-private-key-file` 줄 근처):
   ```yaml
       - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
   ```

   **volumeMounts 섹션**에 추가:
   ```yaml
       - mountPath: /etc/kubernetes/encryption-config.yaml
         name: encryption-config
         readOnly: true
   ```

   **volumes 섹션**에 추가:
   ```yaml
     - hostPath:
         path: /etc/kubernetes/encryption-config.yaml
         type: File
       name: encryption-config
   ```

3. 저장하면 static pod가 자동 재시작된다. apiserver 복구를 대기한다.

   ```bash
   # 30초~1분 소요
   kubectl get nodes
   ```

   > **Note:** apiserver 재시작 중에는 kubectl 명령이 실패한다. 정상.

4. 기존 Secret을 재암호화한다.

   ```bash
   kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   ```

## Step 2: kubelet hardening (all nodes)

마스터와 **모든 워커 노드**에서 각각 실행한다.

1. kubelet config를 수정한다.

   ```bash
   # anonymous auth 비활성화
   sudo sed -i '/anonymous:/,/enabled:/{s/enabled: true/enabled: false/}' /var/lib/kubelet/config.yaml

   # readOnlyPort 비활성화
   sudo sed -i 's/readOnlyPort: 10255/readOnlyPort: 0/' /var/lib/kubelet/config.yaml

   # readOnlyPort 항목이 없는 경우 추가
   grep -q "readOnlyPort" /var/lib/kubelet/config.yaml || \
     echo "readOnlyPort: 0" | sudo tee -a /var/lib/kubelet/config.yaml > /dev/null
   ```

2. kubelet을 재시작한다.

   ```bash
   sudo systemctl restart kubelet
   ```

3. 워커 노드에도 동일하게 적용한다.

   ```bash
   # 각 워커 노드에 SSM 접속 후 위 명령 반복
   aws ssm start-session --target <WORKER_INSTANCE_ID>
   ```

   > **Note:** Packer AMI에 이 설정을 포함시키면 새 노드 생성 시 자동 적용된다. `packer/scripts/k8s-node-setup.sh`에 추가 고려.

## Verify

### etcd 암호화 확인

```bash
# encryption config 파일 존재
sudo ls -la /etc/kubernetes/encryption-config.yaml

# apiserver에 플래그 적용됨
sudo grep encryption-provider-config /etc/kubernetes/manifests/kube-apiserver.yaml

# 테스트: Secret 생성 후 etcd에서 암호화 확인
kubectl create secret generic test-encryption -n default --from-literal=key=value
# etcd에서 직접 확인하려면:
sudo ETCDCTL_API=3 etcdctl get /registry/secrets/default/test-encryption \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key | hexdump -C | head
# "k8s:enc:aescbc:v1:key1" 접두사가 보이면 암호화 성공

kubectl delete secret test-encryption -n default
```

### kubelet 보안 확인

```bash
# anonymous auth
grep -A1 "anonymous:" /var/lib/kubelet/config.yaml
# expected: enabled: false

# readOnlyPort
grep "readOnlyPort" /var/lib/kubelet/config.yaml
# expected: readOnlyPort: 0
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| apiserver 복구 안 됨 | encryption-config 경로 오류 또는 YAML 문법 | `sudo cat /var/log/pods/kube-system_kube-apiserver*/` 로그 확인 |
| kubectl connection refused | apiserver 재시작 중 | 1~2분 대기 |
| Secret replace 실패 | apiserver 아직 미준비 | `kubectl get nodes` 성공 후 재시도 |
| kubelet restart 후 node NotReady | config.yaml 문법 오류 | `journalctl -u kubelet -f` 로그 확인 |

## What's next

- [ArgoCD setup](../deployment/argocd-setup.md)
- Phase 7: 트래픽 전환 (`roadmaps/prod-k8s-migration.md`)
