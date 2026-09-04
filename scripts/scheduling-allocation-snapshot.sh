#!/usr/bin/env bash
# Kubernetes Pod allocation / scheduling evidence collector (read-only)
#
# Usage:
#   ./scripts/scheduling-allocation-snapshot.sh [namespace] [output-directory] [label-selector]
#
# Examples:
#   ./scripts/scheduling-allocation-snapshot.sh prod
#   ./scripts/scheduling-allocation-snapshot.sh scheduling-lab /tmp/scheduling-before 'purpose=scheduling-spread-lab'

set -uo pipefail

NAMESPACE="${1:-prod}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${2:-load-tests/report/scheduling-${NAMESPACE}-${TIMESTAMP}}"
LABEL_SELECTOR="${3:-app=doktori}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl 명령을 찾을 수 없습니다." >&2
  exit 1
fi

if ! CONTEXT="$(kubectl config current-context 2>/dev/null)" || [ -z "$CONTEXT" ]; then
  echo "kubectl current-context가 설정되어 있지 않습니다." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

PASS=0
WARN=0

capture() {
  local output_file="$1"
  shift

  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  } >"${OUTPUT_DIR}/${output_file}" 2>&1

  local status=$?
  if [ "$status" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '[PASS] %s\n' "$output_file"
  else
    WARN=$((WARN + 1))
    printf '[WARN] %s (exit=%d)\n' "$output_file" "$status"
  fi

  return 0
}

printf 'Scheduling allocation snapshot\n'
printf '  context:   %s\n' "$CONTEXT"
printf '  namespace: %s\n' "$NAMESPACE"
printf '  selector:  %s\n' "$LABEL_SELECTOR"
printf '  output:    %s\n' "$OUTPUT_DIR"

capture 00-cluster-info.txt kubectl cluster-info
capture 01-nodes-wide.txt kubectl get nodes -o wide
capture 02-node-topology.txt kubectl get nodes \
  -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,UNSCHEDULABLE:.spec.unschedulable,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,HOSTNAME:.metadata.labels.kubernetes\.io/hostname,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory,PODS:.status.allocatable.pods,TAINTS:.spec.taints[*].key'
capture 03-nodes-describe.txt kubectl describe nodes
capture 04-pods-wide.txt kubectl get pods -n "$NAMESPACE" -o wide --sort-by=.spec.nodeName
capture 05-workload-placement.txt kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
  -o 'custom-columns=COMPONENT:.metadata.labels.component,POD:.metadata.name,REVISION:.metadata.labels.pod-template-hash,NODE:.spec.nodeName,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount'
capture 06-workloads.txt kubectl get deployment,statefulset,daemonset -n "$NAMESPACE" -o wide
capture 07-autoscaling-disruption.txt kubectl get hpa,pdb -n "$NAMESPACE" -o wide
capture 08-priority-classes.txt kubectl get priorityclass -o wide
capture 09-resource-usage-nodes.txt kubectl top nodes
capture 10-resource-usage-pods.txt kubectl top pods -n "$NAMESPACE" --containers
capture 11-events.txt kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp
capture 12-failed-scheduling-events.txt kubectl get events -A \
  --field-selector reason=FailedScheduling --sort-by=.lastTimestamp
capture 13-api-deployment.yaml kubectl get deployment api -n "$NAMESPACE" -o yaml
capture 14-chat-deployment.yaml kubectl get deployment chat -n "$NAMESPACE" -o yaml

PLACEMENT_FILE="${OUTPUT_DIR}/15-placement-summary.tsv"
if {
    printf 'component\tnode\tpod_count\n'
    kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
      -o 'custom-columns=COMPONENT:.metadata.labels.component,NODE:.spec.nodeName' \
      --no-headers 2>/dev/null \
      | awk 'NF >= 2 { count[$1 "\t" $2]++ } END { for (key in count) print key "\t" count[key] }' \
      | sort
  } >"$PLACEMENT_FILE"; then
  PASS=$((PASS + 1))
  printf '[PASS] %s\n' "$(basename "$PLACEMENT_FILE")"
else
  WARN=$((WARN + 1))
  printf '[WARN] %s\n' "$(basename "$PLACEMENT_FILE")"
fi

cat >"${OUTPUT_DIR}/README.txt" <<EOF
Scheduling allocation evidence
==============================
captured_at=${TIMESTAMP}
context=${CONTEXT}
namespace=${NAMESPACE}
label_selector=${LABEL_SELECTOR}

판독 순서
1. 02-node-topology.txt: Ready/cordon/zone/taint가 eligible node 집합을 줄였는지 확인
2. 15-placement-summary.tsv: component별 node 쏠림 확인
3. 03-nodes-describe.txt: Allocated resources가 실제 사용량과 무관하게 requests로 계산됨을 확인
4. 12-failed-scheduling-events.txt: Insufficient cpu/memory, topology, taint, affinity 원인 확인
5. 13/14 deployment YAML: 실제 적용된 spread/affinity/priority가 Git과 같은지 확인
6. 09/10 resource usage: requests 기반 배치와 runtime 사용량의 차이 확인
EOF

printf '\n완료: PASS=%d WARN=%d\n' "$PASS" "$WARN"
printf '결과: %s\n' "$OUTPUT_DIR"
