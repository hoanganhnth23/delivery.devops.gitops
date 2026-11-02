terraform {
  required_version = ">= 1.5.0"

  # State dùng chung, có versioning (bucket tạo một lần bằng gcloud, xem README).
  backend "gcs" {
    bucket = "lithe-paratext-506208-s5-tfstate"
    prefix = "staging"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
