#!/usr/bin/env bash
# 작성 전용 작업에서는 실행하지 않는다. 브로커 노드에서 명시적으로 호출하는 운영 도구다.
set -euo pipefail

if [ "$#" -ne 1 ] || [ "$1" != "--configure" ]; then
  echo "Usage: $0 --configure (run on a reviewed RabbitMQ node after declaring queues)" >&2
  exit 2
fi
command -v jq >/dev/null
command -v rabbitmqctl >/dev/null
command -v rabbitmq-queues >/dev/null
case "$(rabbitmqctl version)" in
  4.3.*) ;;
  *) echo "This reviewed operator script targets RabbitMQ 4.3.x" >&2; exit 1 ;;
esac

cluster_json="$(rabbitmqctl cluster_status --formatter json)"
mapfile -t nodes < <(jq -er '.running_nodes[]' <<<"$cluster_json")
if [ "${#nodes[@]}" -ne 3 ]; then
  echo "Expected exactly three running RabbitMQ nodes; refusing membership changes" >&2
  exit 1
fi

queue_json="$(rabbitmqctl list_queues -p / name type --formatter json)"
for queue in notification.delivery.queue notification.delivery.wait.v2 notification.delivery.dlq; do
  jq -e --arg name "$queue" \
    'any(.[]; .name == $name and .type == "quorum")' <<<"$queue_json" >/dev/null || {
      echo "Expected existing quorum queue: $queue; inspect/drain incompatible queues first" >&2
      exit 1
    }
done

for node in "${nodes[@]}"; do
  rabbitmq-queues grow "$node" all --vhost-pattern '^/$' \
    --queue-pattern '^notification\.delivery\.(queue|wait\.v2|dlq)$' --membership voter
done

# 기존 main queue의 불변 x-arguments를 바꾸지 않고 DLX 인계 보장을 정책으로 설정한다.
rabbitmqctl set_policy -p / --apply-to quorum_queues --priority 10 doktori-notification-safe-dlx \
  '^notification\.delivery\.(queue|wait\.v2)$' \
  '{"dead-letter-strategy":"at-least-once","overflow":"reject-publish"}'

for queue in notification.delivery.queue notification.delivery.wait.v2 notification.delivery.dlq; do
  rabbitmq-queues quorum_status --vhost / "$queue"
done
echo "Membership commands finished. Review every queue's three online members before client cutover."
