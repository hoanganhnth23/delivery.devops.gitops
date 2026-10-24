#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔄 Đang nạp lại cấu hình kong.yml vào Kong Gateway..."

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST http://localhost:8001/config \
  -F "config=@kong.yml")

HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS" | cut -d':' -f2)
BODY=$(echo "$RESPONSE" | grep -v "HTTP_STATUS")

if [ "$HTTP_STATUS" = "201" ] || [ "$HTTP_STATUS" = "200" ]; then
    echo "✅ Cập nhật cấu hình thành công (HTTP $HTTP_STATUS) mà không cần restart container!"
else
    echo "❌ Lỗi khi nạp cấu hình (HTTP $HTTP_STATUS):"
    echo "$BODY"
    exit 1
fi
