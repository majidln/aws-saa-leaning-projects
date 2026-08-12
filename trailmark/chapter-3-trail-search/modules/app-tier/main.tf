resource "aws_security_group" "alb_sg" {
  name        = "${var.prefix}-alb-sg"
  description = "Allow HTTP and HTTPS traffic to ALB"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_ingress_rule" {
  security_group_id = aws_security_group.alb_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  ip_protocol = "tcp"
  to_port     = 80
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.alb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # all protocols/ports
}

resource "aws_lb" "alb" {
  name               = "${var.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false

  tags = {
    Name = "${var.prefix}-alb"
  }
}

data "aws_ami" "amazon-linux-2" {
  most_recent = true

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_security_group" "app_sg" {
  name        = "${var.prefix}-app-sg"
  description = "Allow HTTP and HTTPS traffic to app instances"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.prefix}-app-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_ingress_rule" {
  security_group_id            = aws_security_group.app_sg.id
  referenced_security_group_id = aws_security_group.alb_sg.id

  ip_protocol = "tcp"
  from_port   = var.app_port
  to_port     = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "app_egress_rule" {
  security_group_id = aws_security_group.app_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "app_instance_role" {
  name = "${var.prefix}-app-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SSM Session Manager — shell into instances without a key pair.
resource "aws_iam_role_policy_attachment" "app_instance_ssm" {
  role       = aws_iam_role.app_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app_instance_secrets" {
  name = "${var.prefix}-app-secrets-read"
  role = aws_iam_role.app_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.db_secret_arn]
    }]
  })
}

resource "aws_iam_instance_profile" "app_instance_profile" {
  name = "${var.prefix}-app-instance-profile"
  role = aws_iam_role.app_instance_role.name
}

resource "aws_launch_template" "app_launch_template" {
  name_prefix   = "${var.prefix}-app-"
  description   = "Launch template for app instances"
  image_id      = data.aws_ami.amazon-linux-2.id
  instance_type = var.instance_type

  lifecycle {
    create_before_destroy = true
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.app_instance_profile.name
  }

  # Tiny HTTP stub so the ALB /health check passes. No separate bootstrap script.
  user_data = base64encode(<<-EOT
#!/bin/bash
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1
set -euo pipefail
PORT=${var.app_port}

for i in $(seq 1 30); do
  if [ ! -e /var/run/yum.pid ] || ! kill -0 "$(cat /var/run/yum.pid 2>/dev/null)" 2>/dev/null; then
    break
  fi
  sleep 5
done

yum install -y python3

cat >/opt/trailmark-server.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import os

PORT = int(os.environ.get("PORT", "8080"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        body = b"ok" if path == "/health" else b"trailmark app stub"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PY

cat >/etc/systemd/system/trailmark.service <<EOF
[Unit]
Description=Trailmark app stub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PORT=$PORT
ExecStart=/usr/bin/python3 /opt/trailmark-server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now trailmark.service
EOT
  )

  vpc_security_group_ids = [
    aws_security_group.app_sg.id,
  ]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.prefix}-app-instance"
    }
  }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "${var.prefix}-app-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path = "/health"
  }
}

resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}


resource "aws_autoscaling_group" "app_asg" {
  name                      = "${var.prefix}-app-asg"
  max_size                  = 4
  min_size                  = 1
  health_check_grace_period = 300
  health_check_type         = "ELB"
  desired_capacity          = 1
  force_delete              = true
  # Pin to the concrete LT version so Terraform updates the ASG (and
  # instance refresh runs) whenever user_data changes.
  launch_template {
    id      = aws_launch_template.app_launch_template.id
    version = aws_launch_template.app_launch_template.latest_version
  }
  vpc_zone_identifier = var.app_subnet_ids
  target_group_arns   = [aws_lb_target_group.app_tg.arn]

  timeouts {
    delete = "15m"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-app-instance"
    propagate_at_launch = true
  }
}