# Cụm GKE zonal đang chạy (tạo tay từ trước). Bước này chỉ tham chiếu cụm;
# node pool, router và NAT do Terraform quản lý. Import chính cụm là bước sau
# (xem docs/plans/active/infra-capacity-baseline.md).
data "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone
}

# Node private không có IP public (quota IN_USE_ADDRESSES = 4, đã dùng 1 cho Kong LB),
# nên đi ra Internet (Docker Hub, quay.io, GitHub cho ArgoCD) qua Cloud NAT.
resource "google_compute_router" "nat" {
  name    = "delivery-${var.region}-router"
  region  = var.region
  network = var.network
}

resource "google_compute_router_nat" "nat" {
  name                               = "delivery-${var.region}-nat"
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_container_node_pool" "pool" {
  for_each = var.node_pools

  name     = "${each.key}-pool"
  cluster  = data.google_container_cluster.this.name
  location = var.zone

  node_count = each.value.node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Quota CPU đang ở trần: nâng cấp node theo kiểu xoá trước tạo sau, không surge.
  upgrade_settings {
    max_surge       = 0
    max_unavailable = 1
  }

  network_config {
    enable_private_nodes = true
  }

  node_config {
    machine_type = each.value.machine_type
    disk_size_gb = each.value.disk_size_gb
    disk_type    = each.value.disk_type
    image_type   = "COS_CONTAINERD"

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      "delivery.io/pool" = each.key
    }

    dynamic "taint" {
      for_each = each.value.taint ? [1] : []
      content {
        key    = "delivery.io/pool"
        value  = each.key
        effect = "NO_SCHEDULE"
      }
    }
  }

  lifecycle {
    # staging-up.sh / staging-down.sh đổi số node mỗi buổi.
    ignore_changes = [node_count]
  }

  depends_on = [google_compute_router_nat.nat]
}
