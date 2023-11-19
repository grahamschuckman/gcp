# Documentation: https://cloud.google.com/docs/terraform/resource-management/store-state
# May need to point Google Cloud to where the keys are stored:
# $env:GOOGLE_APPLICATION_CREDENTIALS='.\keys.json'

terraform {
  backend "gcs" {
    bucket = "schuckman-gcp-kubernetes-bucket-tfstate"
    # Will store the default.state file in terraform/state/default.state directory
    prefix      = "terraform/state"
    credentials = "./keys.json"
  }
}