#!/usr/bin/env bash
# Tắt toàn bộ node staging. Dữ liệu (PVC Postgres/Kafka/Redis/Prometheus) vẫn giữ
# và vẫn tính phí đĩa (~vài $/tháng); node thì không còn tính tiền.
set -euo pipefail
source "$(dirname "$0")/staging-env.sh"

# Postgres (CNPG) có PDB minAvailable=1: rút node sẽ kẹt tới 1 giờ. Hibernate dừng pod,
# giữ PVC; staging-up.sh tắt hibernate khi bật lại.
if kubectl -n delivery-staging get cluster delivery-pg >/dev/null 2>&1; then
  echo "==> Hibernate Postgres (giữ dữ liệu)"
  kubectl -n delivery-staging annotate cluster delivery-pg cnpg.io/hibernation=on --overwrite >/dev/null
  for _ in $(seq 1 30); do
    kubectl -n delivery-staging get pod delivery-pg-1 >/dev/null 2>&1 || break
    sleep 5
  done
fi

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
