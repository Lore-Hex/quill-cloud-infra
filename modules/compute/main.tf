# EC2 Auto Scaling Group of Nitro-capable hosts. Each host runs the
# parent process (HTTP listener on :8443, registered with the ALB target
# group) and the enclave (built from the EIF in ECR, started via
# nitro-cli on first boot).
#
# V1 keeps this conservative: 1 instance, no autoscaling, m6i.large. The
# user-data script pulls the latest EIF from ECR, runs build-enclave,
# starts the parent's systemd unit. Operator handles deploys via SSM
# Send-Command for now (CI deploy job to be added in V1.1).

variable "vpc_id" { type = string }
variable "private_subnets" { type = list(string) }
variable "parent_role_name" { type = string }
variable "parent_instance_profile" { type = string }
variable "alb_target_group" { type = string }
variable "ecr_repo_url" { type = string }

data "aws_caller_identity" "current" {}

data "aws_ami" "amzn2023_arm" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
}

resource "aws_security_group" "host" {
  name        = "quill-host"
  description = "Allow ALB to :8443"
  vpc_id      = var.vpc_id
  ingress {
    from_port       = 8443
    to_port         = 8443
    protocol        = "tcp"
    security_groups = []              # restricted to the ALB SG via the listener
    cidr_blocks     = ["10.0.0.0/16"] # only from the VPC
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_template" "host" {
  name_prefix = "quill-host-"
  image_id    = data.aws_ami.amzn2023_arm.id
  # m6g.large (2 vCPUs) is too small: reserving 2 vCPUs for enclaves leaves
  # 0 for the host. m6g.xlarge has 4 vCPUs (2 enclave + 2 host).
  instance_type = "m6g.xlarge"
  iam_instance_profile { name = var.parent_instance_profile }

  vpc_security_group_ids = [aws_security_group.host.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # so containers can reach IMDS
  }

  # Required for Nitro Enclaves: without this, the kernel module never loads
  # and `nitro-cli run-enclave` fails with E19 (no /sys/module/nitro_enclaves).
  enclave_options {
    enabled = true
  }

  # NB: Heredoc body must start at column 0 (no leading whitespace).
  # cloud-init only recognizes `#!` if it's at the very start of the line.
  # We use `<<EOT` (no dash, no stripping) so what we write is what cloud-init sees.
  user_data = base64encode(<<EOT
#!/bin/bash
exec > >(tee -a /var/log/quill-bringup.log) 2>&1
echo "=== quill bring-up start: $(date -Iseconds) ==="
# Deliberately NOT `set -e`: each step should attempt regardless of the others.
# The parent container MUST start (so ALB sees a healthy target); the enclave
# path is best-effort.
set -ux

ECR_URL="${var.ecr_repo_url}"
REGION="us-east-1"
ACCOUNT_ID="${data.aws_caller_identity.current.account_id}"

# 1. Wait up to 60s for network/DNS so dnf can reach the AL2023 mirrors.
for i in $(seq 1 30); do
  if curl -sf --max-time 3 https://amazonlinux-2023-repos-us-east-1.s3.dualstack.us-east-1.amazonaws.com/ -o /dev/null; then
    echo "[$(date -Iseconds)] network OK after $${i} attempts"
    break
  fi
  sleep 2
done

# 2. Base packages. Always required.
dnf install -y docker jq awscli || echo "WARNING: base packages failed"
systemctl enable --now docker

# 3. Nitro Enclaves CLI. If this fails we still bring up the parent.
if ! dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel; then
  echo "WARNING: nitro-cli install failed; enclave path will be unavailable"
fi

# 4. Allocator config (hugepages reservation for enclaves).
if command -v nitro-cli >/dev/null 2>&1; then
  mkdir -p /etc/nitro_enclaves /var/cache/nitro_enclaves /var/log/nitro_enclaves
  # Note the leading `---`: the AL2023 allocator script (a bash YAML
  # parser) skips all lines until it sees a YAML doc-start marker, so
  # without `---` it leaves memory_mib unset and exits "missing memory
  # reservation".
  cat > /etc/nitro_enclaves/allocator.yaml <<'EOF_ALLOC'
---
memory_mib: 2048
cpu_count: 2
EOF_ALLOC
  # `enable --now` won't restart a service that already failed (the package's
  # post-install kicked it before allocator.yaml existed). Use restart explicitly.
  systemctl enable nitro-enclaves-allocator.service || true
  systemctl restart nitro-enclaves-allocator.service \
    || echo "WARNING: allocator service failed to start"
  # Wait briefly so allocator can finish reserving CPUs/memory before run-enclave.
  for i in $(seq 1 15); do
    if systemctl is-active --quiet nitro-enclaves-allocator.service; then break; fi
    sleep 2
  done
  id ec2-user >/dev/null 2>&1 && usermod -aG ne ec2-user || true
  # nitro-cli build-enclave reads these from env. Without them: E51.
  cat > /etc/profile.d/nitro_enclaves.sh <<'EOF_PROF'
export NITRO_CLI_ARTIFACTS=/var/cache/nitro_enclaves
export NITRO_CLI_BLOBS=/usr/share/nitro_enclaves/blobs
EOF_PROF
fi
export NITRO_CLI_ARTIFACTS=/var/cache/nitro_enclaves
export NITRO_CLI_BLOBS=/usr/share/nitro_enclaves/blobs

# 5. ECR login via the instance role (no static creds).
if ! aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR_URL"; then
  echo "FATAL: ECR login failed; cannot pull images"
  exit 1
fi

# 6. Parent container — runs regardless of enclave state. Hardened.
docker pull "$ECR_URL:parent-latest"
docker rm -f quill-parent 2>/dev/null || true
docker run -d --restart=unless-stopped --network=host \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --name quill-parent \
  -e QUILL_ENCLAVE_RELAY_PORT=8001 \
  -e QUILL_USAGE_TABLE_NAME=quill_usage \
  -e QUILL_DEVICE_KEYS_BUCKET="quill-device-keys-$${ACCOUNT_ID}" \
  -e QUILL_AWS_REGION="$REGION" \
  -e QUILL_USE_DEV_TRANSPORT=false \
  -e AWS_DEFAULT_REGION="$REGION" \
  "$ECR_URL:parent-latest"

# 7. Best-effort enclave bring-up.
if command -v nitro-cli >/dev/null 2>&1; then
  docker pull "$ECR_URL:enclave-latest" \
    || { echo "WARNING: enclave image pull failed"; exit 0; }
  if nitro-cli build-enclave \
      --docker-uri "$ECR_URL:enclave-latest" \
      --output-file /opt/quill.eif > /var/log/quill-eif-build.log 2>&1; then
    nitro-cli describe-enclaves --output json 2>/dev/null \
      | jq -r '.[].EnclaveID' \
      | xargs -r -I{} nitro-cli terminate-enclave --enclave-id {}
    nitro-cli run-enclave \
      --eif-path /opt/quill.eif \
      --memory 2048 --cpu-count 2 \
      --enclave-cid 16 \
      || echo "WARNING: nitro-cli run-enclave failed"
  else
    echo "WARNING: enclave EIF build failed (see /var/log/quill-eif-build.log)"
  fi
fi

echo "=== quill bring-up end: $(date -Iseconds) ==="
EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "quill-host" }
  }
}

resource "aws_autoscaling_group" "host" {
  name                      = "quill-host"
  desired_capacity          = 1
  min_size                  = 1
  max_size                  = 1 # V1 single-instance; no autoscaling
  vpc_zone_identifier       = var.private_subnets
  health_check_type         = "ELB"
  health_check_grace_period = 300
  target_group_arns         = [var.alb_target_group]
  launch_template {
    id      = aws_launch_template.host.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "quill-host"
    propagate_at_launch = true
  }
}

output "asg_name" { value = aws_autoscaling_group.host.name }
