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
# NLB target group for TLS-passthrough on :8444 → enclave. Optional during
# Phase 2 cutover; pass null while only the ALB target is wired.
variable "nlb_target_group" {
  type    = string
  default = null
}
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
  description = "Allow ALB → :8443 (HTTP) and NLB → :8444 (TCP passthrough)"
  vpc_id      = var.vpc_id
  ingress {
    description = "ALB into parent FastAPI (admin trust health)"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # in-VPC only; ALB SG covers the rest
  }
  ingress {
    description = "NLB into parent TCP pump into enclave-terminated TLS"
    from_port   = 8444
    to_port     = 8444
    protocol    = "tcp"
    # NLBs preserve client source IP, so the SG must allow the public
    # internet here. The parent's TCP pump never auths or inspects;
    # the enclave's TLS handshake is the gate.
    cidr_blocks = ["0.0.0.0/0"]
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

# 5a. vsock-proxy for Bedrock (parent listens on CID-ANY:8003, forwards
# raw bytes to bedrock-runtime.us-east-1.amazonaws.com:443). The Go enclave
# inside opens AF_VSOCK to (3, 8003) and does TLS itself; parent never
# decrypts the prompt path.
if command -v vsock-proxy >/dev/null 2>&1; then
  cat > /etc/nitro_enclaves/vsock-proxy-quill.yaml <<'EOF_VSP'
allowlist:
- {address: bedrock-runtime.us-east-1.amazonaws.com, port: 443}
- {address: kms.us-east-1.amazonaws.com, port: 443}
- {address: s3.us-east-1.amazonaws.com, port: 443}
EOF_VSP
  cat > /etc/systemd/system/quill-vsock-proxy-bedrock.service <<'EOF_BEDROCK'
[Unit]
Description=Quill vsock-proxy: Bedrock-runtime
After=network-online.target

[Service]
ExecStart=/usr/bin/vsock-proxy 8003 bedrock-runtime.us-east-1.amazonaws.com 443 --config /etc/nitro_enclaves/vsock-proxy-quill.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_BEDROCK
  systemctl daemon-reload
  systemctl enable --now quill-vsock-proxy-bedrock.service \
    || echo "WARNING: vsock-proxy for Bedrock failed to start"
fi

# 5b. ECR login via the instance role (no static creds).
if ! aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR_URL"; then
  echo "FATAL: ECR login failed; cannot pull images"
  exit 1
fi

# 6. Parent container — runs regardless of enclave state.
#
# AF_VSOCK socket() is BLOCKED by Docker's default seccomp profile, and the
# (currently empty) container default-drop list also strips the kernel cap
# implementation needs. We use seccomp=unconfined (V1 acceptable: parent
# code is open-source + signed; there's no untrusted user payload running
# inside the parent container).
docker pull "$ECR_URL:parent-latest"
docker rm -f quill-parent 2>/dev/null || true
docker run -d --restart=unless-stopped --network=host \
  --device=/dev/vsock:/dev/vsock \
  --security-opt seccomp=unconfined \
  --name quill-parent \
  -e QUILL_ENCLAVE_RELAY_PORT=8001 \
  -e QUILL_USAGE_TABLE_NAME=quill_usage \
  -e QUILL_DEVICE_KEYS_BUCKET="quill-device-keys-$${ACCOUNT_ID}" \
  -e QUILL_AWS_REGION="$REGION" \
  -e QUILL_USE_DEV_TRANSPORT=false \
  -e QUILL_BOOTSTRAP_SERVER=true \
  -e QUILL_BEDROCK_VSOCK_PROXY=3:8003 \
  -e AWS_DEFAULT_REGION="$REGION" \
  --entrypoint /app/.venv/bin/uvicorn \
  "$ECR_URL:parent-latest" \
  quill_parent.main:app --host 0.0.0.0 --port 8443 --loop asyncio

# 7. Enclave bring-up via a systemd unit so it auto-restarts if it dies.
if command -v nitro-cli >/dev/null 2>&1; then
  docker pull "$ECR_URL:enclave-latest" \
    || { echo "WARNING: enclave image pull failed"; exit 0; }
  if nitro-cli build-enclave \
      --docker-uri "$ECR_URL:enclave-latest" \
      --output-file /opt/quill.eif > /var/log/quill-eif-build.log 2>&1; then
    cat > /etc/systemd/system/quill-enclave.service <<'EOF_UNIT'
[Unit]
Description=Quill Nitro Enclave
After=nitro-enclaves-allocator.service
Requires=nitro-enclaves-allocator.service

[Service]
# nitro-cli run-enclave returns once the enclave is launched; the enclave
# itself runs as a sibling process, so this is a oneshot that we keep
# "active" via RemainAfterExit. ExecStop tears it down cleanly.
Type=oneshot
RemainAfterExit=yes
Environment=NITRO_CLI_ARTIFACTS=/var/cache/nitro_enclaves
Environment=NITRO_CLI_BLOBS=/usr/share/nitro_enclaves/blobs
ExecStartPre=-/usr/bin/bash -c '/usr/bin/nitro-cli describe-enclaves --output json | /usr/bin/jq -r ".[].EnclaveID" | xargs -r -I{} /usr/bin/nitro-cli terminate-enclave --enclave-id {}'
ExecStart=/usr/bin/nitro-cli run-enclave --eif-path /opt/quill.eif --memory 2048 --cpu-count 2 --enclave-cid 16
ExecStop=/usr/bin/bash -c '/usr/bin/nitro-cli describe-enclaves --output json | /usr/bin/jq -r ".[].EnclaveID" | xargs -r -I{} /usr/bin/nitro-cli terminate-enclave --enclave-id {}'

[Install]
WantedBy=multi-user.target
EOF_UNIT
    systemctl daemon-reload
    systemctl enable --now quill-enclave.service \
      || echo "WARNING: quill-enclave.service failed to start"
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
  target_group_arns         = compact([var.alb_target_group, var.nlb_target_group])
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
