#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🛑 Đang dừng Kong Gateway container..."
docker compose down
echo "✅ Đã tắt Kong Gateway container."
