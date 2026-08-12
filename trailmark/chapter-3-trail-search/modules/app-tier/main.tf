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

resource "aws_security_group" "app-sg" {
  name        = "${var.prefix}-app-sg"
  description = "Allow HTTP and HTTPS traffic to app instances"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.prefix}-app-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_ingress_rule" {
  security_group_id            = aws_security_group.app-sg.id
  referenced_security_group_id = aws_security_group.alb_sg.id

  ip_protocol = "tcp"
  from_port   = var.app_port
  to_port     = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "app_egress_rule" {
  security_group_id = aws_security_group.app-sg.id
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol        = "-1"
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

# SSM Session Manager access only, for now — lets us shell into instances
# without a key pair. Secrets Manager access is added once db-tier exists.
resource "aws_iam_role_policy_attachment" "app_instance_ssm" {
  role       = aws_iam_role.app_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
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

  user_data = base64encode(templatefile("${path.module}/src/bootstrap.sh", {
    port = var.app_port
  }))

  vpc_security_group_ids = [
    aws_security_group.app-sg.id,
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
    path = "/"
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
  launch_template {
    id      = aws_launch_template.app_launch_template.id
    version = "$Latest"
  }
  vpc_zone_identifier = var.app_subnet_ids
  target_group_arns   = [aws_lb_target_group.app_tg.arn]

  instance_maintenance_policy {
    min_healthy_percentage = 90
    max_healthy_percentage = 120
  }

  initial_lifecycle_hook {
    name                 = "app-lifecycle-hook"
    default_result       = "CONTINUE"
    heartbeat_timeout    = 300
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
  }

  timeouts {
    delete = "15m"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-app-instance"
    propagate_at_launch = true
  }
}