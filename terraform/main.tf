provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# -------------------------------------------------------------
# Module 1: VPC Network & Cloud NAT
# -------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  project_id    = var.project_id
  region        = var.region
  network_name  = var.network_name
  subnet_name   = var.subnet_name
  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr
}

# -------------------------------------------------------------
# Module 2: Artifact Registry
# -------------------------------------------------------------
module "artifact_registry" {
  source = "./modules/artifact-registry"

  project_id    = var.project_id
  location      = var.region
  repository_id = var.artifact_repo_id
  description   = "Docker repository for Delivery platform"
}

# -------------------------------------------------------------
# Module 3: IAM & Service Accounts
# -------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_id = var.project_id
}

# -------------------------------------------------------------
# Module 4: GKE Cluster
# -------------------------------------------------------------
module "gke" {
  source = "./modules/gke"

  project_id                    = var.project_id
  region                        = var.region
  cluster_name                  = var.cluster_name
  network                       = module.vpc.network_self_link
  subnetwork                    = module.vpc.subnet_self_link
  pods_secondary_range_name     = module.vpc.pods_secondary_range_name
  services_secondary_range_name = module.vpc.services_secondary_range_name
  node_service_account          = module.iam.gke_node_sa_email

  initial_node_count = var.initial_node_count
  node_count_min     = var.node_count_min
  node_count_max     = var.node_count_max
  machine_type       = var.machine_type
  disk_size_gb       = var.disk_size_gb
  disk_type          = var.disk_type
  spot_instances     = var.spot_instances

  depends_on = [
    module.vpc,
    module.iam
  ]
}
