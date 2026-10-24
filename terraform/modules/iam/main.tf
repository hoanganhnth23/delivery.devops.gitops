# -------------------------------------------------------------
# Service Account for GKE Nodes
# -------------------------------------------------------------
resource "google_service_account" "gke_nodes" {
  account_id   = var.gke_sa_name
  display_name = "GKE Node Pool Service Account"
  project      = var.project_id
}

locals {
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader"
  ]
}

resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset(local.gke_node_roles)
  project  = var.project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# -------------------------------------------------------------
# Service Account for CI/CD Pipeline (GitHub Actions)
# -------------------------------------------------------------
resource "google_service_account" "cicd" {
  account_id   = var.cicd_sa_name
  display_name = "GitHub Actions CI/CD Service Account"
  project      = var.project_id
}

locals {
  cicd_roles = [
    "roles/artifactregistry.writer",
    "roles/container.developer"
  ]
}

resource "google_project_iam_member" "cicd_roles" {
  for_each = toset(local.cicd_roles)
  project  = var.project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.cicd.email}"
}
