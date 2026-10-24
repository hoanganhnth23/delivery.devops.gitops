variable "project_id" {
  description = "The GCP project ID"
  type        = string
  default     = "lithe-paratext-506208-s5"
}

variable "region" {
  description = "GCP Region for all regional resources"
  type        = string
  default     = "asia-southeast1"
}

variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "delivery-vpc"
}

variable "subnet_name" {
  description = "Name of the primary GKE subnetwork"
  type        = string
  default     = "delivery-gke-subnet"
}

variable "subnet_cidr" {
  description = "Primary CIDR block for GKE nodes"
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR block for GKE Pods"
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR block for GKE Services"
  type        = string
  default     = "10.30.0.0/20"
}

variable "artifact_repo_id" {
  description = "Artifact Registry repository ID"
  type        = string
  default     = "delivery-repo"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "delivery-cluster"
}

variable "initial_node_count" {
  description = "Initial number of nodes (set to 0 for cost-saving hibernation)"
  type        = number
  default     = 0
}

variable "node_count_min" {
  description = "Minimum node count per zone for autoscaler"
  type        = number
  default     = 0
}

variable "node_count_max" {
  description = "Maximum node count per zone for autoscaler"
  type        = number
  default     = 8
}

variable "machine_type" {
  description = "GKE Node machine type"
  type        = string
  default     = "e2-standard-2"
}

variable "disk_size_gb" {
  description = "Disk size per GKE node in GB"
  type        = number
  default     = 50
}

variable "disk_type" {
  description = "Disk type for GKE nodes"
  type        = string
  default     = "pd-balanced"
}

variable "spot_instances" {
  description = "Whether to use Spot (preemptible) VMs for worker nodes to save costs"
  type        = bool
  default     = false
}
