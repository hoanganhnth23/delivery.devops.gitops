#!/usr/bin/env bash
# Bật staging cho một buổi làm việc/test tải.
#   bash scripts/staging-up.sh                                   # mỗi pool core/data/elastic 1 node
#   NODE_POOLS="core-pool:1 data-pool:1 elastic-pool:2" bash scripts/staging-up.sh
# Xong buổi PHẢI chạy scripts/staging-down.sh, nếu không node chạy cả đêm.
set -euo pipefail
source "$(dirname "$0")/staging-env.sh"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900s}"

# Data trước (PVC Postgres/Kafka), rồi core (ArgoCD, operator), rồi elastic.
for entry in $NODE_POOLS; do
  pool="${entry%%:*}"; nodes="${entry##*:}"
  echo "==> Resize ${pool} lên ${nodes} node"
  "${GCLOUD[@]}" container clusters resize "$CLUSTER" --zone "$ZONE" \
    --node-pool "$pool" --num-nodes "$nodes" --quiet
done

"${GCLOUD[@]}" container clusters get-credentials "$CLUSTER" --zone "$ZONE" >/dev/null
echo "==> Chờ node Ready"
kubectl wait --for=condition=Ready nodes --all --timeout="$WAIT_TIMEOUT"

# Đánh thức Postgres nếu staging-down.sh đã hibernate (chờ webhook sẵn sàng).
if kubectl -n delivery-staging get cluster delivery-pg >/dev/null 2>&1; then
  echo "==> Bỏ hibernate Postgres"
  for i in {1..12}; do
    if kubectl -n delivery-staging annotate cluster delivery-pg cnpg.io/hibernation=off --overwrite >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
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
