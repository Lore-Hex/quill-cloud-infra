#!/usr/bin/env bash
# Adopt the live AWS-EU analytics layout into Terraform state.
#
# Every resource this root module describes already EXISTS. It was provisioned
# before this configuration, which is the normal state of affairs for
# infrastructure that predates its own Terraform. So the first thing that
# happens here is an import, not an apply.
#
# The failure mode this prevents is not subtle: `terraform apply` against an
# empty state would CREATE a second ClickHouse node, identity, secret and VPC
# connectors beside the ones holding and carrying production analytics. The
# node's root EBS volume IS the analytics store.
#
# Safe to re-run: anything already in state is skipped, and anything absent from
# AWS is reported rather than imported. The optional dsql-connect-drain policy
# is probed and adopted when present.
#
# Usage:
#   ACCOUNT_ID=330422590279 REGION=eu-west-3 bash envs/aws-eu-prod/import.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ACCOUNT="${ACCOUNT_ID:-330422590279}"
REGION="${REGION:-eu-west-3}"
INSTANCE="${INSTANCE_ID:-i-025ed1c1766f61290}"
SG="${SECURITY_GROUP_ID:-sg-09e23d1eb299afb9c}"
ROLE="${ROLE_NAME:-tr-eu-clickhouse-role}"
PROFILE="${INSTANCE_PROFILE_NAME:-tr-eu-clickhouse-instance-profile}"
PRIMARY_POLICY="${INLINE_POLICY_NAME:-tr-eu-clickhouse-policy}"
SSM_POLICY="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
SECRET="${SECRET_NAME:-quill/tr-eu-clickhouse-password}"
CLICKHOUSE_CONNECTOR="${CLICKHOUSE_VPC_CONNECTOR_NAME:-tr-eu-vpc}"
PRIVATE_CONNECTOR="${PRIVATE_EGRESS_VPC_CONNECTOR_NAME:-tr-eu-vpc-private}"

# Snapshot state ONCE. Re-running `terraform state list` per resource and
# discarding its stderr makes an error -- a held lock, a backend problem --
# indistinguishable from "not in state", and the script then imports something
# it already manages.
# The S3 backend ERRORS on a brand-new state file where the gcs and azurerm
# backends return empty output with exit 0 -- so "nothing is managed yet" and
# "could not read state" arrive through the same exit code. Only the specific
# first-run message is treated as an empty snapshot; every other failure still
# refuses to guess.
if STATE="$(terraform state list 2>&1)"; then
  :
elif printf '%s' "$STATE" | grep -q "No state file was found"; then
  STATE=""
else
  printf '%s
' "$STATE" >&2
  echo "terraform state list failed; refusing to guess what is already managed" >&2
  exit 1
fi

adopt() {
  local addr="$1" id="$2"
  if printf '%s\n' "$STATE" | grep -qxF "$addr"; then
    echo "  already in state: ${addr}"
    return
  fi
  if [ -z "$id" ]; then
    echo "  not in AWS, terraform apply would create it: ${addr}"
    return
  fi
  terraform import -input=false \
    -var "account_id=${ACCOUNT}" \
    -var "region=${REGION}" \
    "$addr" "$id" >/dev/null && {
      STATE="${STATE}"$'\n'"$addr"
      echo "  imported: ${addr}"
    }
}

# Each helper answers "what is this resource's import id", with THREE possible
# outcomes, not two: present (prints the id), absent (prints nothing, exits 0),
# and COULD NOT ASK (message on stderr, exits 1). An expired credential, denied
# action, throttled endpoint or broken network must never read as "not in AWS";
# otherwise the next apply could collide with the live analytics layout.
#
# Callers assign these via VAR="$(helper)" as standalone assignments, where the
# substitution's exit status IS the assignment's status and `set -e` stops the
# script. Nesting a helper inside another command's arguments would discard that
# status.
PROBE_OUTPUT=""
probe() {
  local what="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    PROBE_OUTPUT="$out"
    return 0
  fi
  if printf '%s' "$out" | grep -qiE \
    "ResourceNotFoundException|NoSuchEntity|Invalid[A-Za-z0-9]+[.]NotFound|not found|does not exist"; then
    return 10
  fi
  printf 'could not ask AWS about %s:\n%s\n' "$what" "$out" >&2
  return 1
}

fixed_import_id() {
  local what="$1" id="$2"; shift 2
  probe "$what" "$@" \
    && printf '%s' "$id" \
    || { [ $? -eq 10 ] && return 0 || return 1; }
}

instance_import_id() {
  fixed_import_id "instance $INSTANCE" "$INSTANCE" \
    aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE"
}

security_group_import_id() {
  fixed_import_id "security group $SG" "$SG" \
    aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG"
}

role_import_id() {
  fixed_import_id "role $ROLE" "$ROLE" \
    aws iam get-role --region "$REGION" --role-name "$ROLE"
}

instance_profile_import_id() {
  fixed_import_id "instance profile $PROFILE" "$PROFILE" \
    aws iam get-instance-profile --region "$REGION" \
      --instance-profile-name "$PROFILE"
}

role_policy_import_id() {
  local policy="$1"
  fixed_import_id "inline policy $ROLE/$policy" "${ROLE}:${policy}" \
    aws iam get-role-policy --region "$REGION" \
      --role-name "$ROLE" --policy-name "$policy"
}

managed_attachment_import_id() {
  local arn="$1"
  probe "managed policy attachment $ROLE/$arn" \
    aws iam list-attached-role-policies --region "$REGION" \
      --role-name "$ROLE" \
      --query "AttachedPolicies[?PolicyArn=='${arn}'].PolicyArn | [0]" \
      --output text \
    && { [ -z "$PROBE_OUTPUT" ] || [ "$PROBE_OUTPUT" = "None" ] || printf '%s/%s' "$ROLE" "$arn"; } \
    || { [ $? -eq 10 ] && return 0 || return 1; }
}

secret_import_id() {
  probe "secret $SECRET" \
    aws secretsmanager describe-secret --region "$REGION" \
      --secret-id "$SECRET" --query ARN --output text \
    && { [ -z "$PROBE_OUTPUT" ] || [ "$PROBE_OUTPUT" = "None" ] || printf '%s' "$PROBE_OUTPUT"; } \
    || { [ $? -eq 10 ] && return 0 || return 1; }
}

vpc_connector_import_id() {
  local name="$1"
  probe "App Runner VPC connector $name" \
    aws apprunner list-vpc-connectors --region "$REGION" \
      --query "VpcConnectors[?VpcConnectorName=='${name}' && Status=='ACTIVE'].VpcConnectorArn | [0]" \
      --output text \
    && { [ -z "$PROBE_OUTPUT" ] || [ "$PROBE_OUTPUT" = "None" ] || printf '%s' "$PROBE_OUTPUT"; } \
    || { [ $? -eq 10 ] && return 0 || return 1; }
}

# Refuse to import into the right-looking names in the wrong account. This is a
# probe too: failure to ask STS is fatal, not evidence that the account is empty.
probe "caller identity" aws sts get-caller-identity --region "$REGION" \
  --query Account --output text
if [ "$PROBE_OUTPUT" != "$ACCOUNT" ]; then
  echo "AWS CLI is authenticated to account $PROBE_OUTPUT, expected $ACCOUNT" >&2
  exit 1
fi

echo "=== AWS-EU analytics identity, network and secret metadata"
SG_ID="$(security_group_import_id)"
ROLE_ID="$(role_import_id)"
PROFILE_ID="$(instance_profile_import_id)"
SECRET_ID="$(secret_import_id)"
adopt 'module.clickhouse.aws_security_group.clickhouse' "$SG_ID"
adopt 'module.clickhouse.aws_iam_role.node' "$ROLE_ID"
adopt 'module.clickhouse.aws_iam_instance_profile.node' "$PROFILE_ID"
adopt 'module.clickhouse.aws_secretsmanager_secret.clickhouse_password' "$SECRET_ID"

echo "=== AWS-EU analytics role policies"
PRIMARY_POLICY_ID="$(role_policy_import_id "$PRIMARY_POLICY")"
# This grant may genuinely be absent. Only a successful AWS answer is allowed
# to establish that; access-denied, auth and endpoint errors stop the script.
SSM_ATTACHMENT_ID="$(managed_attachment_import_id "$SSM_POLICY")"
adopt "module.clickhouse.aws_iam_role_policy.inline[\"${PRIMARY_POLICY}\"]" "$PRIMARY_POLICY_ID"
adopt "module.clickhouse.aws_iam_role_policy_attachment.managed[\"${SSM_POLICY}\"]" "$SSM_ATTACHMENT_ID"

echo "=== AWS-EU analytics node"
NODE_ID="$(instance_import_id)"
adopt 'module.clickhouse.aws_instance.node' "$NODE_ID"

echo "=== App Runner VPC connectors (the service itself is out of scope)"
CLICKHOUSE_CONNECTOR_ID="$(vpc_connector_import_id "$CLICKHOUSE_CONNECTOR")"
PRIVATE_CONNECTOR_ID="$(vpc_connector_import_id "$PRIVATE_CONNECTOR")"
adopt 'aws_apprunner_vpc_connector.clickhouse' "$CLICKHOUSE_CONNECTOR_ID"
adopt 'aws_apprunner_vpc_connector.private_egress' "$PRIVATE_CONNECTOR_ID"

echo
echo "=== drift (expect: no changes, or additions you can explain)"
terraform plan -input=false -no-color \
  -var "account_id=${ACCOUNT}" \
  -var "region=${REGION}" \
  2>&1 | tail -6
