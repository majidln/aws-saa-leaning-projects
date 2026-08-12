resource "aws_security_group" "db_sg" {
  name        = "${var.prefix}-db-sg"
  description = "Allow traffic from the app tier"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.prefix}-db-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_ingress_rule" {
  security_group_id            = aws_security_group.db_sg.id
  referenced_security_group_id = var.app_sg

  ip_protocol = "tcp"
  from_port   = var.db_port
  to_port     = var.db_port
}

resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "${var.prefix}-db-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = {
    Name = "${var.prefix}-db-subnet-group"
  }
}

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%^&*()-_=+[]{}|:,.<>?"
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 2
}

resource "aws_secretsmanager_secret" "generated_password" {
  name        = "${var.prefix}-db-password"
  description = "Production database credentials"

  tags = {
    Name = "${var.prefix}-db-password"
  }
}

resource "aws_db_instance" "db_instance" {
  allocated_storage      = 20
  identifier             = "${var.prefix}-db-instance"
  db_name                = "trailmark"
  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.id
  engine                 = "postgres"
  engine_version         = "14"
  instance_class         = "db.t3.micro"
  port                   = var.db_port
  username               = "postgres"
  password               = random_password.db_password.result
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  publicly_accessible    = false
  multi_az               = false
  skip_final_snapshot    = true
}

resource "aws_secretsmanager_secret_version" "generated_password" {
  secret_id = aws_secretsmanager_secret.generated_password.id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.db_password.result
    host     = aws_db_instance.db_instance.address
    port     = aws_db_instance.db_instance.port
    dbname   = aws_db_instance.db_instance.db_name
    engine   = "postgres"
  })
}
