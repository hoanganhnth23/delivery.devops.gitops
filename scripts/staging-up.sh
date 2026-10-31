#!/usr/bin/env bash
# Bật staging cho một buổi làm việc/test tải.
#   bash scripts/staging-up.sh            # 3 node e2-standard-2 (nấc 1, đủ 19 service)
#   NODES=4 bash scripts/staging-up.sh    # bật sẵn nhiều node hơn cho buổi test nặng
# Xong buổi PHẢI chạy scripts/staging-down.sh, nếu không node chạy cả đêm.
set -euo pipefail
source "$(dirname "$0")/staging-env.sh"
NODES="${NODES:-3}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900s}"

echo "==> Resize ${NODE_POOL} lên ${NODES} node"
"${GCLOUD[@]}" container clusters resize "$CLUSTER" --zone "$ZONE" \
  --node-pool "$NODE_POOL" --num-nodes "$NODES" --quiet

# Autoscaler chỉ bật trong buổi làm việc: HPA tăng replica -> pod Pending -> thêm node.
echo "==> Bật autoscaling 0..${MAX_NODES}"
"${GCLOUD[@]}" container node-pools update "$NODE_POOL" --cluster "$CLUSTER" --zone "$ZONE" \
  --enable-autoscaling --min-nodes 0 --max-nodes "$MAX_NODES" --quiet

"${GCLOUD[@]}" container clusters get-credentials "$CLUSTER" --zone "$ZONE" >/dev/null
echo "==> Chờ node Ready"
kubectl wait --for=condition=Ready nodes --all --timeout="$WAIT_TIMEOUT"

# Đánh thức Postgres nếu staging-down.sh đã hibernate.
if kubectl -n delivery-staging get cluster delivery-pg >/dev/null 2>&1; then
  echo "==> Bỏ hibernate Postgres"
  kubectl -n delivery-staging annotate cluster delivery-pg cnpg.io/hibernation=off --overwrite >/dev/null
fi

# GCP Secret Manager & External Secrets Operator credentials (idempotent).
bash "$(dirname "$0")/setup-gcp-secret-manager.sh"

# Secret runtime/JWT fallback (idempotent, chỉ tạo khi thiếu).
bash "$(dirname "$0")/staging-secrets.sh"

for ns in argocd monitoring delivery-staging; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    echo "==> Chờ pod Ready trong ${ns} (Java + Kafka mất ~8-12 phút sau khi bật từ 0)"
    kubectl wait --for=condition=Ready pods --all -n "$ns" \
      --field-selector=status.phase!=Succeeded --timeout="$WAIT_TIMEOUT" \
      || echo "!! ${ns} còn pod chưa Ready: kubectl get pods -n ${ns}"
  fi
done

cat <<MSG

Staging đã bật. Mở giao diện:
  kubectl -n monitoring port-forward svc/delivery-monitoring-grafana 3000:80
  kubectl -n monitoring get svc   # tìm service Prometheus để port-forward 9091:9090
Kết thúc buổi: bash scripts/staging-down.sh
MSG
