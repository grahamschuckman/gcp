# https://registry.terraform.io/providers/hashicorp/google/latest/docs
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.6.0"
    }
  }
}

provider "google" {
  project     = "kubernetesterraform-405517"
  region      = "us-east4"
  credentials = "./keys.json"
}
