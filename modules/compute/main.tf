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
variable "alb_target_group" { type = string }
variable "ecr_repo_url" { type = string }

data "aws_iam_instance_profile" "parent_host" {
  name = "quill-parent-host"
}

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
  description = "Allow ALB → :8443"
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
  name_prefix   = "quill-host-"
  image_id      = data.aws_ami.amzn2023_arm.id
  instance_type = "m6g.large"
  iam_instance_profile { name = data.aws_iam_instance_profile.parent_host.name }

  vpc_security_group_ids = [aws_security_group.host.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # so containers can reach IMDS
  }

  user_data = base64encode(<<-EOF
    #!/usr/bin/env bash
    set -eu
    dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel docker jq
    systemctl enable --now docker
    usermod -aG ne ec2-user
    aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${var.ecr_repo_url}
    docker pull ${var.ecr_repo_url}:enclave-latest
    nitro-cli build-enclave --docker-uri ${var.ecr_repo_url}:enclave-latest --output-file /opt/quill.eif
    nitro-cli run-enclave --eif-path /opt/quill.eif --memory 2048 --cpu-count 2
    docker pull ${var.ecr_repo_url}:parent-latest
    docker run -d --restart=always --network=host \
      -e QUILL_ENCLAVE_RELAY_PORT=8001 \
      -e QUILL_USAGE_TABLE_NAME=quill_usage \
      -e QUILL_DEVICE_KEYS_BUCKET=quill-device-keys \
      ${var.ecr_repo_url}:parent-latest
  EOF
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
