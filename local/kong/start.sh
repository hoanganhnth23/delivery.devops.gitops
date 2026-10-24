#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=================================================="
echo "🚀 Khởi động Kong API Gateway (Local DB-less Mode)"
echo "=================================================="

# 1. Kiểm tra Docker Daemon
if ! docker info >/dev/null 2>&1; then
    echo "⚠️  Docker daemon chưa bật. Đang khởi chạy Docker.app..."
    open -a Docker || true
    echo "⏳ Đang đợi Docker daemon sẵn sàng..."
    while ! docker info >/dev/null 2>&1; do
        sleep 2
        printf "."
    done
    echo ""
    echo "✅ Docker daemon đã sẵn sàng!"
fi

# 2. Khởi chạy Kong container
echo "📦 Đang khởi động container Kong qua Docker Compose..."
docker compose up -d

# 3. Đợi Kong sẵn sàng
echo "⏳ Đang kiểm tra trạng thái Kong Gateway..."
MAX_RETRIES=20
COUNT=0
READY=false

while [ $COUNT -lt $MAX_RETRIES ]; do
    if curl -s http://localhost:8001/status >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
    COUNT=$((COUNT + 1))
    printf "."
done
echo ""

if [ "$READY" = true ]; then
    echo "=================================================="
    echo "🎉 KONG API GATEWAY ĐÃ SẴN SÀNG!"
    echo "=================================================="
    echo "👉 Proxy HTTP (Client gọi vào): http://localhost:8000"
    echo "👉 Admin API:                   http://localhost:8001"
    echo "👉 Kong Manager (Web GUI):       http://localhost:8002"
    echo "=================================================="
else
    echo "❌ Lỗi: Kong không phản hồi sau $MAX_RETRIES giây."
    echo "Xem logs bằng: docker logs delivery-kong-local"
    exit 1
fi
