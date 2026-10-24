#!/usr/bin/env bash
# Tạo secret runtime cho staging. Idempotent: secret đã có thì giữ nguyên
# (trừ khi ROTATE=1). Không in giá trị secret ra màn hình, không ghi vào Git.
#
#   bash scripts/staging-secrets.sh
#   APP_SECRETS_ENV_FILE=~/delivery-staging.env bash scripts/staging-secrets.sh   # thêm SMTP_*, MAPBOX_*, VNPAY_*
#   ROTATE=1 bash scripts/staging-secrets.sh   # tạo lại (JWT cũ hết hiệu lực -> user phải đăng nhập lại)
set -euo pipefail
NS="${NS:-delivery-staging}"
ROTATE="${ROTATE:-0}"

need() { command -v "$1" >/dev/null || { echo "Thiếu lệnh: $1" >&2; exit 1; }; }
need kubectl; need openssl

exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }
should_create() {
  if exists "$1"; then
    if [[ "$ROTATE" == "1" ]]; then kubectl -n "$NS" delete secret "$1" >/dev/null; return 0; fi
    echo "= $1 đã tồn tại, giữ nguyên"; return 1
  fi
  return 0
}

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

# 1) Secret dùng chung, mount tại /run/secrets (Spring configtree: tên file = tên property).
if should_create delivery-runtime-secrets; then
  kubectl -n "$NS" create secret generic delivery-runtime-secrets \
    --from-literal=internal-secret="$(openssl rand -hex 32)" \
    --from-literal=registration-canary-hash-key="$(openssl rand -hex 32)" >/dev/null
  echo "+ delivery-runtime-secrets"
fi

# 2) Cặp khoá RSA ký JWT cho auth-service (private PKCS8 PEM, public X509 PEM).
if should_create delivery-jwt; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/private.pem" 2>/dev/null
  openssl pkey -in "$tmp/private.pem" -pubout -out "$tmp/public.pem"
  kubectl -n "$NS" create secret generic delivery-jwt \
    --from-file=private.pem="$tmp/private.pem" --from-file=public.pem="$tmp/public.pem" >/dev/null
  echo "+ delivery-jwt"
fi

# 3) Tuỳ chọn: biến môi trường bổ sung từ file KEY=VALUE nằm ngoài repo.
if [[ -n "${APP_SECRETS_ENV_FILE:-}" ]]; then
  kubectl -n "$NS" create secret generic delivery-app-secrets \
    --from-env-file="$APP_SECRETS_ENV_FILE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "+ delivery-app-secrets (từ $APP_SECRETS_ENV_FILE)"
fi

echo "Xong. Pod đang chạy cần restart để nhận secret mới: kubectl -n $NS rollout restart deploy"
