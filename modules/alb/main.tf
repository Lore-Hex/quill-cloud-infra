variable "vpc_id" { type = string }
variable "public_subnets" { type = list(string) }
variable "domain" { type = string }
variable "api_sub" { type = string }

# ACM cert for the api subdomain. DNS validation is manual via Cloudflare;
# Terraform creates the cert resource and surfaces the validation CNAME.
resource "aws_acm_certificate" "api" {
  domain_name       = "${var.api_sub}.${var.domain}"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "alb" {
  name        = "quill-alb"
  description = "Public ingress 443; egress to ECS targets"
  vpc_id      = var.vpc_id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "main" {
  name               = "quill-api"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnets
}

resource "aws_lb_target_group" "parent" {
  name        = "quill-parent"
  port        = 8443
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id
  health_check {
    path                = "/health"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.api.arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.parent.arn
  }
}

output "dns_name" {
  value = aws_lb.main.dns_name
}

output "target_group_arn" {
  value = aws_lb_target_group.parent.arn
}

# The CNAMEs the operator must add in Cloudflare to complete ACM validation.
output "acm_validation_records" {
  value = [
    for o in aws_acm_certificate.api.domain_validation_options :
    {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]
}
