terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

variable "project_name" {
  default = "drupal-network"
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${count.index + 1}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
    Tier = "private"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-nat"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
# Application Load Balancer Security Group
resource "aws_security_group" "alb" {
  name        = "drupal-network-alb-sg"
  description = "Allow HTTP traffic to the load balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "drupal-network-alb-sg"
  }
}

# Application Security Group
resource "aws_security_group" "app" {
  name        = "drupal-network-app-sg"
  description = "Allow application traffic from the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "drupal-network-app-sg"
  }
}

# Database Security Group
resource "aws_security_group" "db" {
  name        = "drupal-network-db-sg"
  description = "Allow MySQL only from the application tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from application"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "drupal-network-db-sg"
  }
}

# Private RDS Subnet Group
resource "aws_db_subnet_group" "drupal" {
  name       = "drupal-network-db-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "drupal-network-db-subnets"
  }
}

# MySQL RDS Database - Multi-AZ
resource "aws_db_instance" "drupal" {
  identifier                  = "drupal-network-db"
  engine                      = "mysql"
  engine_version              = "8.0"
  instance_class              = "db.t3.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  db_name                     = "drupal"
  username                    = "drupaladmin"
  manage_master_user_password = true

  multi_az               = true
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.drupal.name
  vpc_security_group_ids = [aws_security_group.db.id]

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Name = "drupal-network-db"
  }
}

# Find the manually created Drupal EC2 instance
data "aws_instance" "drupal_app" {
  instance_id = "i-04162bc3c0b34fa14"
}

# ALB target group
resource "aws_lb_target_group" "drupal" {
  name     = "drupal-network-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/core/install.php"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "drupal-network-tg"
  }
}

# Register the Drupal EC2 instance
resource "aws_lb_target_group_attachment" "drupal" {
  target_group_arn = aws_lb_target_group.drupal.arn
  target_id        = data.aws_instance.drupal_app.id
  port             = 80
}

# Application Load Balancer
resource "aws_lb" "drupal" {
  name               = "drupal-network-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "drupal-network-alb"
  }
}

# HTTP listener
resource "aws_lb_listener" "drupal" {
  load_balancer_arn = aws_lb.drupal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.drupal.arn
  }
}

# Load balancer DNS output
output "drupal_alb_url" {
  value = "http://${aws_lb.drupal.dns_name}"
}

# EFS security group: allow NFS from Drupal application servers
resource "aws_security_group" "efs" {
  name        = "drupal-network-efs-sg"
  description = "Allow NFS from Drupal app servers"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "drupal-network-efs-sg"
  }
}

# Shared filesystem for Drupal uploaded files
resource "aws_efs_file_system" "drupal" {
  creation_token = "drupal-network-shared-files"
  encrypted      = true

  tags = {
    Name = "drupal-network-efs"
  }
}

# EFS mount targets in both private availability zones
resource "aws_efs_mount_target" "drupal" {
  count           = 2
  file_system_id  = aws_efs_file_system.drupal.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# Second Drupal application server in eu-west-2b
resource "aws_instance" "drupal_app_2" {
  ami                    = data.aws_instance.drupal_app.ami
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private[1].id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = "prestashop-key"
  iam_instance_profile   = "drupal-ec2-ssm-role"

  tags = {
    Name = "drupal-app-server-2"
  }

  depends_on = [aws_efs_mount_target.drupal]
}

# Register the second server with the existing ALB target group
resource "aws_lb_target_group_attachment" "drupal_app_2" {
  target_group_arn = aws_lb_target_group.drupal.arn
  target_id        = aws_instance.drupal_app_2.id
  port             = 80
}

output "drupal_second_instance_id" {
  value = aws_instance.drupal_app_2.id
}

output "drupal_efs_id" {
  value = aws_efs_file_system.drupal.id
}

resource "aws_launch_template" "drupal" {
  name_prefix   = "drupal-asg-"
  image_id      = "ami-03094287345b6c69b"
  instance_type = "t3.micro"
  key_name      = "prestashop-key"

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    name = "drupal-ec2-ssm-role"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -eux
    mkdir -p /var/www/html/sites/default/files
    grep -q 'fs-09b6623e68572895a.efs.eu-west-2.amazonaws.com:/' /etc/fstab || echo 'fs-09b6623e68572895a.efs.eu-west-2.amazonaws.com:/ /var/www/html/sites/default/files nfs4 defaults,_netdev,nfsvers=4.1 0 0' >> /etc/fstab
    mount -a
    systemctl enable --now apache2
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "drupal-asg-instance"
    }
  }
}

resource "aws_autoscaling_group" "drupal" {
  name                = "drupal-network-asg"
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.drupal.arn]

  launch_template {
    id      = aws_launch_template.drupal.id
    version = "$Latest"
  }

  health_check_type         = "ELB"
  health_check_grace_period = 300

  depends_on = [aws_efs_mount_target.drupal]

  tag {
    key                 = "Name"
    value               = "drupal-asg-instance"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "drupal_cpu" {
  name                   = "drupal-cpu-target-tracking"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.drupal.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0
  }
}

output "drupal_asg_name" {
  value = aws_autoscaling_group.drupal.name
}