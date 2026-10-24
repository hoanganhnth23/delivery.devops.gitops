#!/usr/bin/env bash
# Tắt toàn bộ node staging. Dữ liệu (PVC Postgres/Kafka/Redis/Prometheus) vẫn giữ
# và vẫn tính phí đĩa (~vài $/tháng); node thì không còn tính tiền.
set -euo pipefail
source "$(dirname "$0")/staging-env.sh"

# Tắt autoscaler TRƯỚC khi resize: nếu không, pod Pending sẽ kéo node bật lại.
echo "==> Tắt autoscaling của ${NODE_POOL}"
"${GCLOUD[@]}" container node-pools update "$NODE_POOL" --cluster "$CLUSTER" --zone "$ZONE" \
  --no-enable-autoscaling --quiet

echo "==> Resize ${NODE_POOL} về 0 node"
"${GCLOUD[@]}" container clusters resize "$CLUSTER" --zone "$ZONE" \
  --node-pool "$NODE_POOL" --num-nodes 0 --quiet

count=$("${GCLOUD[@]}" compute instances list \
  --filter="name~^gke-${CLUSTER}- AND status=RUNNING" --format="value(name)" | wc -l | tr -d ' ')
if [[ "$count" != "0" ]]; then
  echo "!! Vẫn còn ${count} VM GKE đang RUNNING — kiểm tra lại trên Console." >&2
  exit 1
fi
echo "OK: không còn node nào chạy."
