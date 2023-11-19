# resource "random_id" "bucket_prefix" {
#   byte_length = 8
# }

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