# Public-facing NLB that does TCP passthrough to the parent's TCP-pump
# listener on port 8444. From the parent, the bytes go straight over vsock
# to the enclave, which terminates TLS using a cert generated INSIDE the
# attested binary. The NLB never decrypts; AWS infrastructure never holds
# plaintext prompt content.
#
# Lives alongside the existing ALB (modules/alb), which keeps serving the
# admin/trust/health HTTPS endpoints on a different hostname. The split
# is intentional: the NLB path has zero L7 inspection so the trust story
# holds; the ALB path has the L7 features we want for the operator-facing
# endpoints, where there's no prompt content to leak.

variable "vpc_id" { type = string }
variable "public_subnets" { type = list(string) }

resource "aws_lb" "tls_passthrough" {
  name                             = "quill-prompt"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = var.public_subnets
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "parent_tcp" {
  name        = "quill-parent-tcp"
  port        = 8444
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id
  health_check {
    protocol            = "TCP"
    port                = 8444
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
  # Preserve client source IP all the way to the parent. The parent doesn't
  # log it, but it's exposed to the enclave for any future per-client rate
  # limiting that doesn't depend on body content.
  preserve_client_ip = true
}

resource "aws_lb_listener" "tcp_443" {
  load_balancer_arn = aws_lb.tls_passthrough.arn
  port              = 443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.parent_tcp.arn
  }
}

output "dns_name" {
  value = aws_lb.tls_passthrough.dns_name
}

output "target_group_arn" {
  value = aws_lb_target_group.parent_tcp.arn
}
