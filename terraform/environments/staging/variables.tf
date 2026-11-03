variable "project_id" {
  type    = string
  default = "lithe-paratext-506208-s5"
}

variable "region" {
  type    = string
  default = "asia-southeast1"
}

variable "zone" {
  description = "Cụm staging là zonal; PVC (PG/Kafka/Redis) nằm ở zone này nên mọi pool phải cùng zone."
  type        = string
  default     = "asia-southeast1-a"
}

variable "cluster_name" {
  type    = string
  default = "delivery-cluster"
}

variable "network" {
  type    = string
  default = "default"
}

# Mỗi pool một vai trò. Kích thước (số node) do scripts/staging-up.sh / staging-down.sh
# đổi trong ngày, nên Terraform chỉ đặt cấu hình và bỏ qua node_count.
#
# Quota project hiện tại (2026-11-02): CPUS_ALL_REGIONS = 12, C3_CPUS = 8, E2_CPUS = 8.
# 3 pool × 4 vCPU = 12 là trần; muốn thêm node phải xin tăng quota trước.
variable "node_pools" {
  type = map(object({
    machine_type = string
    node_count   = number
    disk_size_gb = number
    disk_type    = string
    taint        = bool # true: chỉ pod có toleration delivery.io/pool=<key> mới vào được
  }))
  default = {
    # Hệ thống + nhóm static/event: ArgoCD, monitoring, operator, kube-system, 15 service nhẹ.
    core = {
      machine_type = "e2-standard-4"
      node_count   = 1
      disk_size_gb = 50
      disk_type    = "pd-balanced"
      taint        = false
    }
    # Tầng data: Postgres (CNPG), Kafka (Strimzi), Redis. Máy CPU mạnh, không bị app chen.
    data = {
      machine_type = "c3-standard-4"
      node_count   = 1
      disk_size_gb = 50
      disk_type    = "pd-balanced"
      taint        = true
    }
    # Nhóm elastic: Kong + auth/restaurant/order/tracking/flashsale. Sau này bật HPA + autoscaler ở đây.
    elastic = {
      machine_type = "c3-standard-4"
      node_count   = 1
      disk_size_gb = 50
      disk_type    = "pd-balanced"
      taint        = true
    }
  }
}

# --- k6 load test trên Cloud Run Job (loadtest.tf) ---
variable "k6_image" {
  description = "Build từ load-testing/cloudrun/Dockerfile, push vào Artifact Registry delivery-repo."
  type        = string
  default     = "asia-southeast1-docker.pkg.dev/lithe-paratext-506208-s5/delivery-repo/k6-loadtest:2026-11-03"
}

variable "k6_cpu" {
  description = "Một task Cloud Run tối đa 8 vCPU; tier2 (~500 rps, ~4k VU) nằm gọn trong 1 task."
  type        = string
  default     = "8"
}

variable "k6_memory" {
  type    = string
  default = "16Gi"
}

variable "k6_base_url" {
  description = "Kong LB staging (IP public, đi thẳng qua Internet trong cùng vùng)."
  type        = string
  default     = "http://34.87.64.137"
}
