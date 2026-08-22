# Migrating the Azure enclave state

The `quill-cloud-proxy/tools/azure-enclave` module deliberately kept local
state. Move that state into this module's Azure Blob backend before using this
copy. Do not import the live resources again: the existing state already owns
them.

From the `quill-cloud-infra` repository root, with the two repositories checked
out as siblings:

```bash
# 1. Copy the current local state forward. Keep the source directory intact.
cp ../quill-cloud-proxy/tools/azure-enclave/terraform.tfstate \
  envs/azure-tee/terraform.tfstate

# 2. Initialize this root and accept Terraform's state migration prompt.
cd envs/azure-tee
terraform init -migrate-state

# 3. Verify the migrated state still describes the live scaffolding exactly.
terraform plan
```

The plan must report `No changes`. If it does not, stop and investigate; do not
apply and do not delete the source state.

Only after the no-change plan is verified, delete `tools/azure-enclave/` from
the `quill-cloud-proxy` repository in a separate change. That deletion happens
in the other repository, never here.
