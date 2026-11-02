#!/usr/bin/env bash
# Cấu hình dùng chung cho staging-up.sh / staging-down.sh. Ghi đè bằng biến môi trường.
PROJECT_ID="${PROJECT_ID:-lithe-paratext-506208-s5}"
CLUSTER="${CLUSTER:-delivery-cluster}"
ZONE="${ZONE:-asia-southeast1-a}"
# Node pool theo vai trò, cấu hình trong terraform/environments/staging (máy, label, taint).
# Script chỉ đổi số node mỗi buổi: "<pool>:<số node khi bật>".
# Quota project: 12 vCPU toàn cầu -> 3 node × 4 vCPU là trần (2026-11-02).
NODE_POOLS="${NODE_POOLS:-core-pool:1 data-pool:1 elastic-pool:1}"
# Pool cũ e2-standard-2 (đã thay bằng các pool trên); script vẫn đưa nó về 0 nếu còn tồn tại.
LEGACY_POOLS="${LEGACY_POOLS:-staging-pool}"
GCLOUD=(gcloud --project "$PROJECT_ID")
