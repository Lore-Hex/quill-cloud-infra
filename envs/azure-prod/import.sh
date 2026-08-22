#!/usr/bin/env bash
# Adopt the live Azure analytics node into Terraform state.
#
# Every resource this root module describes already EXISTS. It was provisioned
# before this configuration, which is the normal state of affairs for
# infrastructure that predates its own Terraform. So the first thing that
# happens here is an import, not an apply.
#
# The failure mode this prevents is not subtle: `terraform apply` against an
# empty state would CREATE a second ClickHouse node, a second subnet and a
# second identity beside the ones holding the data, then hand the control plane
# an address with no rows behind it. The node's disk IS the analytics store.
#
# Safe to re-run: anything already in state is skipped, and anything absent from
# Azure is reported rather than imported.
#
# Usage:
#   SUBSCRIPTION_ID=... KEY_VAULT_ID=... bash envs/azure-prod/import.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SUB="${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID}"
RG="${RESOURCE_GROUP:-tr-azure}"
VNET="${VNET:-vnet-prod}"
SUBNET="${SUBNET:-snet-clickhouse}"
NSG="${NSG:-tr-azure-clickhouse-nsg}"
IDENTITY="${IDENTITY:-tr-azure-clickhouse-identity}"
VM="${VM:-tr-azure-clickhouse-1}"
KV_ID="${KEY_VAULT_ID:?set KEY_VAULT_ID (the vault holding the ClickHouse password)}"

base="/subscriptions/${SUB}/resourceGroups/${RG}/providers"

# Snapshot state ONCE. Re-running `terraform state list` per resource and
# discarding its stderr makes an error -- a held lock, a backend problem --
# indistinguishable from "not in state", and the script then imports something
# it already manages.
STATE="$(terraform state list)" || {
  echo "terraform state list failed; refusing to guess what is already managed" >&2
  exit 1
}

adopt() {
  local addr="$1" id="$2"
  if printf '%s\n' "$STATE" | grep -qxF "$addr"; then
    echo "  already in state: ${addr}"
    return
  fi
  if [ -z "$id" ]; then
    echo "  not in Azure, terraform apply would create it: ${addr}"
    return
  fi
  # ARM returns user-assigned identity ids with a lowercase "resourcegroups"
  # segment; the azurerm ID parser accepts only the camel-cased form.
  id="$(printf %s "$id" | sed 's#/resourcegroups/#/resourceGroups/#')"
  terraform import -input=false \
    -var "subscription_id=${SUB}" \
    -var "key_vault_id=${KV_ID}" \
    "$addr" "$id" >/dev/null && {
      STATE="${STATE}"$'\n'"$addr"
      echo "  imported: ${addr}"
    }
}

echo "=== azure analytics node"
adopt 'module.clickhouse.azurerm_network_security_group.clickhouse' \
  "$(az network nsg show -g "$RG" -n "$NSG" --query id -o tsv 2>/dev/null || true)"
adopt 'module.clickhouse.azurerm_subnet.clickhouse' \
  "$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SUBNET" --query id -o tsv 2>/dev/null || true)"
adopt 'module.clickhouse.azurerm_subnet_network_security_group_association.clickhouse' \
  "$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SUBNET" --query id -o tsv 2>/dev/null || true)"
adopt 'module.clickhouse.azurerm_user_assigned_identity.node' \
  "$(az identity show -g "$RG" -n "$IDENTITY" --query id -o tsv 2>/dev/null || true)"
adopt 'module.clickhouse.azurerm_network_interface.node' \
  "$(az network nic show -g "$RG" -n "${VM}VMNic" --query id -o tsv 2>/dev/null || true)"
adopt 'module.clickhouse.azurerm_linux_virtual_machine.node' \
  "$(az vm show -g "$RG" -n "$VM" --query id -o tsv 2>/dev/null || true)"

echo "=== the vault grant"
# Read through ARM, not `az role assignment list --assignee`: that form resolves
# the principal through Microsoft Graph, which is unreliable on this tenant
# (measured hanging past 120s with a valid token) and whose failures are
# indistinguishable from "the grant does not exist".
PRINCIPAL="$(az identity show -g "$RG" -n "$IDENTITY" --query principalId -o tsv 2>/dev/null || true)"
if [ -n "$PRINCIPAL" ]; then
  ROLE_ID="$(az role definition list --name "Key Vault Secrets User" --query "[0].id" -o tsv)"
  RA_ID="$(az rest --method get --url \
    "https://management.azure.com${KV_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'${PRINCIPAL}'" \
    2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
for a in json.load(sys.stdin).get("value", []):
    if a["properties"]["roleDefinitionId"] == want:
        print(a["id"])
        break
' "$ROLE_ID")"
  adopt 'azurerm_role_assignment.clickhouse_reads_its_password' "$RA_ID"
else
  echo "  identity not found; nothing to adopt"
fi

echo
echo "=== drift (expect: no changes, or additions you can explain)"
terraform plan -input=false -no-color \
  -var "subscription_id=${SUB}" \
  -var "key_vault_id=${KV_ID}" \
  2>&1 | tail -6
