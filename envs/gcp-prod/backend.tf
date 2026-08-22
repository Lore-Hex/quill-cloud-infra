// GCP's state lives in GCP, not in the S3 bucket envs/prod uses.
//
// This is a deliberate departure from the existing root module, and the reason
// is the same one the rest of the platform is built on: no cloud may be a
// prerequisite for provisioning another. Putting GCP's Terraform state in an
// S3 bucket means an AWS outage -- or an expired AWS credential, or a bucket
// policy change -- blocks every GCP change, including the ones you would be
// making to route around AWS. That is exactly the hub dependency the
// multi-cloud split exists to avoid, reintroduced through the back door of a
// state file.
//
// It also means each cloud's blast radius stays its own: a Terraform mistake
// here cannot corrupt the state that describes AWS or Azure.
//
// BOOTSTRAP (one-time, before the first `terraform init` here):
//
//   gcloud storage buckets create gs://quill-cloud-proxy-tfstate \
//     --project=quill-cloud-proxy --location=us-central1 \
//     --uniform-bucket-level-access
//
// Versioning is worth turning on at the same time; a state file is the one
// object where "restore the previous version" is the whole recovery plan:
//
//   gcloud storage buckets update gs://quill-cloud-proxy-tfstate --versioning
//
// Locking needs no separate table: the gcs backend uses object generation
// preconditions so only the writer holding the current generation can update
// state.
terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    bucket = "quill-cloud-proxy-tfstate"
    prefix = "envs/gcp-prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
