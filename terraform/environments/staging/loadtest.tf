# Máy tạo tải k6 chạy trong GCP (cùng vùng với cụm), thay cho laptop VN→SG.
# Lý do: run tier2 ngày 2026-11-02 có ~8.5k/13.8k lỗi là timeout phía k6, Kong/server không lỗi tương ứng.
# Cloud Run có quota CPU riêng, không ăn vào CPUS_ALL_REGIONS = 12 của Compute Engine.
# Cách dùng: load-testing/cloudrun/README.md.

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

# data/ (token, shipper, nhà hàng) upload trước mỗi buổi; results/ do handleSummary ghi.
resource "google_storage_bucket" "loadtest" {
  name                        = "${var.project_id}-loadtest"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_service_account" "k6" {
  account_id   = "k6-loadtest"
  display_name = "k6 load test (Cloud Run Job)"
}

# Chỉ đọc/ghi đúng bucket load test.
resource "google_storage_bucket_iam_member" "k6_bucket" {
  bucket = google_storage_bucket.loadtest.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.k6.email}"
}

resource "google_cloud_run_v2_job" "k6" {
  name                = "k6-loadtest"
  location            = var.region
  deletion_protection = false

  template {
    # Muốn tải lớn hơn 1 task: tăng task_count và chia tải bằng --execution-segment.
    task_count  = 1
    parallelism = 1

    template {
      service_account       = google_service_account.k6.email
      timeout               = "3600s"
      max_retries           = 0
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2" # bắt buộc cho volume GCS

      containers {
        image = var.k6_image

        resources {
          limits = {
            cpu    = var.k6_cpu
            memory = var.k6_memory
          }
        }

        env {
          name  = "BASE_URL"
          value = var.k6_base_url
        }
        env {
          name  = "SCENARIO"
          value = "enterprise-suite.js"
        }
        env {
          name  = "PROFILE"
          value = "baseline" # CiAMS 5 CCU; ghi đè bằng --update-env-vars PROFILE=tier2
        }

        volume_mounts {
          name       = "lt"
          mount_path = "/mnt/lt"
        }
      }

      volumes {
        name = "lt"
        gcs {
          bucket    = google_storage_bucket.loadtest.name
          read_only = false
        }
      }
    }
  }

  depends_on = [google_project_service.run, google_storage_bucket_iam_member.k6_bucket]
}
