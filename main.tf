# resource "random_id" "bucket_prefix" {
#   byte_length = 8
# }

# Bucket to store Terraform state. Bit of a chicken and the egg scenario without chaos-code-manager
resource "google_storage_bucket" "state" {
  name          = "schuckman-gcp-kubernetes-bucket-tfstate"
  force_destroy = false
  location      = "US"
  storage_class = "STANDARD"
  versioning {
    enabled = false
  }
  #   encryption {
  #     default_kms_key_name = google_kms_crypto_key.terraform_state_bucket.id
  #   }
  #   depends_on = [
  #     google_project_iam_member.default
  #   ]
}

# GCP is different from AWS in that you need to enable various services in a given project before using them
# The reason seems to be that it signals to the CSP that resources will be used, allowing for more efficient resource utilization
# Also prevents accidental misuse of APIs, so lower security threat
# Needed to add the Service Usage Admin role to the service account to have permissions to view and enable new project services
# Needed to also enable the Cloud Resource Manager API: https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=166095251970
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_service
resource "google_project_service" "compute" {
  service = "compute.googleapis.com"
}

resource "google_project_service" "container" {
  service = "container.googleapis.com"
}

# Create a new VPC called main. Could use the existing default VPC, but this is a good exercise
# Need to associate Compute Network Admin role with the service account to have permissions to create the VPC
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network
resource "google_compute_network" "main" {
  name                            = "main"
  routing_mode                    = "REGIONAL"
  auto_create_subnetworks         = false
  mtu                             = 1460
  delete_default_routes_on_create = false

  depends_on = [
    google_project_service.compute,
    google_project_service.container
  ]
}
