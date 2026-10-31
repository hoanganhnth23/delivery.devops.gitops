#!/usr/bin/env bash
# Khởi tạo và đồng bộ bí mật lên Google Cloud Secret Manager (GSM).
# Idempotent: nếu secret đã tồn tại trên GCP thì giữ nguyên phiên bản cũ.
#
#   bash scripts/setup-gcp-secret-manager.sh
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-lithe-paratext-506208-s5}"
SA_NAME="eso-secret-manager-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
ESO_NS="external-secrets"

need() { command -v "$1" >/dev/null || { echo "Thiếu lệnh: $1" >&2; exit 1; }; }
need gcloud; need openssl

echo "==> Kiểm tra Secret Manager API trên project ${PROJECT_ID}"
gcloud services enable secretmanager.googleapis.com --project="${PROJECT_ID}"

# Hàm tạo hoặc bỏ qua secret trên GCP Secret Manager
create_or_skip_secret() {
  local secret_name="$1"
  local secret_value="$2"

  if gcloud secrets describe "${secret_name}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "  = Secret ${secret_name} đã tồn tại trên GCP Secret Manager, giữ nguyên."
  else
    echo "  + Đang tạo secret: ${secret_name}"
    printf "%s" "${secret_value}" | gcloud secrets create "${secret_name}" \
      --project="${PROJECT_ID}" \
      --replication-policy="automatic" \
      --data-file=- >/dev/null
  fi
}

# Đọc bí mật hiện có từ Kubernetes nếu có, tránh làm mất hiệu lực session cũ
get_k8s_secret() {
  local secret_name="$1"
  local json_key="$2"
  if command -v kubectl >/dev/null && command -v jq >/dev/null && kubectl -n delivery-staging get secret "${secret_name}" >/dev/null 2>&1; then
    kubectl -n delivery-staging get secret "${secret_name}" -o json | jq -r ".data[\"${json_key}\"] // empty" | base64 -d 2>/dev/null || true
  fi
}

echo "==> 1. Thiết lập bí mật Runtime trên GCP Secret Manager"

# Khóa bí mật nội bộ
INTERNAL_SECRET="$(get_k8s_secret "delivery-runtime-secrets" "internal-secret")"
[[ -z "${INTERNAL_SECRET}" ]] && INTERNAL_SECRET="$(openssl rand -hex 32)"
create_or_skip_secret "delivery-internal-secret" "${INTERNAL_SECRET}"

CANARY_KEY="$(get_k8s_secret "delivery-runtime-secrets" "registration-canary-hash-key")"
[[ -z "${CANARY_KEY}" ]] && CANARY_KEY="$(openssl rand -hex 32)"
create_or_skip_secret "delivery-canary-hash-key" "${CANARY_KEY}"

WEB_BFF_KEY="$(get_k8s_secret "delivery-runtime-secrets" "web-bff.encryption-key-base64")"
[[ -z "${WEB_BFF_KEY}" ]] && WEB_BFF_KEY="$(openssl rand -base64 32)"
create_or_skip_secret "delivery-web-bff-key" "${WEB_BFF_KEY}"

# Cặp khóa RSA ký JWT cho auth-service
if gcloud secrets describe "delivery-jwt-private" --project="${PROJECT_ID}" >/dev/null 2>&1 && \
   gcloud secrets describe "delivery-jwt-public" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "  = Cặp khóa delivery-jwt-* đã tồn tại trên GCP Secret Manager, giữ nguyên."
else
  JWT_PRIVATE="$(get_k8s_secret "delivery-jwt" "private.pem")"
  JWT_PUBLIC="$(get_k8s_secret "delivery-jwt" "public.pem")"

  if [[ -n "${JWT_PRIVATE}" && -n "${JWT_PUBLIC}" ]]; then
    echo "  = Lấy cặp khóa delivery-jwt từ Kubernetes cluster để tải lên GCP Secret Manager..."
  else
    echo "  + Đang sinh cặp khóa RSA 2048-bit mới..."
    tmp="$(mktemp -d)"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/private.pem" 2>/dev/null
    openssl pkey -in "$tmp/private.pem" -pubout -out "$tmp/public.pem"
    JWT_PRIVATE="$(cat "$tmp/private.pem")"
    JWT_PUBLIC="$(cat "$tmp/public.pem")"
    rm -rf "$tmp"
  fi

  create_or_skip_secret "delivery-jwt-private" "${JWT_PRIVATE}"
  create_or_skip_secret "delivery-jwt-public" "${JWT_PUBLIC}"
fi

echo "==> 2. Kiểm tra Service Account cho External Secrets Operator"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "  + Tạo GCP Service Account: ${SA_NAME}"
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="ESO Secret Manager Accessor" \
    --project="${PROJECT_ID}"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor"
else
  echo "  = Service Account ${SA_EMAIL} đã sẵn sàng."
fi

echo "==> 3. Cung cấp Service Account Key cho cụm Kubernetes (nếu kết nối được)"
if command -v kubectl >/dev/null && kubectl cluster-info >/dev/null 2>&1; then
  kubectl get ns "${ESO_NS}" >/dev/null 2>&1 || kubectl create ns "${ESO_NS}" >/dev/null
  if ! kubectl -n "${ESO_NS}" get secret gcp-secret-manager-credentials >/dev/null 2>&1; then
    echo "  + Đang tạo key JSON mới cho ${SA_EMAIL} và nạp vào Kubernetes secret..."
    key_tmp="$(mktemp -d)"
    gcloud iam service-accounts keys create "${key_tmp}/key.json" \
      --iam-account="${SA_EMAIL}" \
      --project="${PROJECT_ID}"
    kubectl -n "${ESO_NS}" create secret generic gcp-secret-manager-credentials \
      --from-file=service-account-key.json="${key_tmp}/key.json"
    rm -rf "${key_tmp}"
    echo "  + Đã tạo secret gcp-secret-manager-credentials trong namespace ${ESO_NS}."
  else
    echo "  = Secret gcp-secret-manager-credentials đã tồn tại trong ${ESO_NS}."
  fi
else
  echo "  ! Cụm Kubernetes chưa bật hoặc không kết nối được. Lệnh này sẽ tự chạy lại khi khởi động cụm bằng staging-up.sh."
fi

echo "==> Hoàn tất cài đặt Google Cloud Secret Manager cho hệ thống Delivery."
