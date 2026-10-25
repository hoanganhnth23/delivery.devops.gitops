#!/usr/bin/env bash
# Cấu hình dùng chung cho staging-up.sh / staging-down.sh. Ghi đè bằng biến môi trường.
PROJECT_ID="${PROJECT_ID:-lithe-paratext-506208-s5}"
CLUSTER="${CLUSTER:-delivery-cluster}"
ZONE="${ZONE:-asia-southeast1-a}"
# staging-pool: e2-standard-2, autoscaling 0..8 (default-pool e2-standard-4 đã xoá 2026-10-25).
NODE_POOL="${NODE_POOL:-staging-pool}"
MAX_NODES="${MAX_NODES:-8}"
GCLOUD=(gcloud --project "$PROJECT_ID")
