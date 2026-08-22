// Azure's state lives in AZURE, not in the S3 bucket envs/prod uses.
//
// This is a deliberate departure from the existing root module, and the reason
// is the same one the rest of the platform is built on: no cloud may be a
// prerequisite for provisioning another. Putting Azure's Terraform state in an
// S3 bucket means an AWS outage -- or an expired AWS credential, or a bucket
// policy change -- blocks every Azure change, including the ones you would be
// making to route around AWS. That is exactly the hub dependency the
// multi-cloud split exists to avoid, reintroduced through the back door of a
// state file.
//
// It also means each cloud's blast radius stays its own: a Terraform mistake
// here cannot corrupt the state that describes AWS.
//
// BOOTSTRAP (one-time, before the first `terraform init` here):
//
//   az group create -n tr-tfstate -l uaenorth
//   az storage account create -n trquilltfstate -g tr-tfstate -l uaenorth \
//     --sku Standard_LRS --kind StorageV2 \
//     --allow-blob-public-access false --min-tls-version TLS1_2
//   az storage container create -n tfstate --account-name trquilltfstate \
//     --auth-mode login
//
// Versioning is worth turning on at the same time; a state file is the one
// object where "restore the previous version" is the whole recovery plan:
//
//   az storage account blob-service-properties update \
//     --account-name trquilltfstate -g tr-tfstate --enable-versioning true
//
// Locking needs no separate table: the azurerm backend uses a blob lease.
terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  backend "azurerm" {
    resource_group_name  = "tr-tfstate"
    storage_account_name = "trquilltfstate"
    container_name       = "tfstate"
    key                  = "envs/azure-prod/terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
