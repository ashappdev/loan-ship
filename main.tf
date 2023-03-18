# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.52.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.4.3"
    }
  }
  required_version = ">= 1.1.0"

  cloud {
    organization = "arudland-test-dev"

    workspaces {
      name = "arudland-example-app"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "example_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "example_subnet_1" {
  cidr_block = "10.0.1.0/24"
  vpc_id     = aws_vpc.example_vpc.id
}

resource "aws_subnet" "example_subnet_2" {
  cidr_block = "10.0.2.0/24"
  vpc_id     = aws_vpc.example_vpc.id
}

resource "aws_security_group" "load_balancer_sg" {
  name_prefix = "load-balancer-sg"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_sg" {
  name_prefix = "ecs-sg"

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_sg.id]
  }
}

resource "aws_security_group" "rds_sg" {
  name_prefix = "rds-sg"

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }
}

resource "aws_elasticache_subnet_group" "example_cache_subnet_group" {
  name       = "example_cache_subnet_group"
  subnet_ids = [aws_subnet.example_subnet_1.id, aws_subnet.example_subnet_2.id]
}

resource "aws_elasticache_cluster" "example_cache" {
  cluster_id         = "example-cache"
  node_type          = "cache.t2.micro"
  engine             = "redis"
  num_cache_nodes    = 1
  subnet_group_name  = aws_elasticache_subnet_group.example_cache_subnet_group.name
  security_group_ids = [aws_security_group.ecs_sg.id]
}

resource "aws_db_subnet_group" "example_db_subnet_group" {
  name       = "example_db_subnet_group"
  subnet_ids = [aws_subnet.example_subnet_1.id, aws_subnet.example_subnet_2.id]
}

resource "aws_db_instance" "example_db" {
  identifier             = "example-db"
  allocated_storage      = 20
  storage_type           = "gp2"
  engine                 = "postgres"
  engine_version         = "13.3"
  instance_class         = "db.t2.micro"
  db_name                = "example_db"
  username               = "admin"
  password               = "password1234"
  db_subnet_group_name   = aws_db_subnet_group.example_db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
}

resource "aws_sns_topic" "example_topic" {
  name = "example_topic"
}

resource "aws_lb" "example_lb" {
  name               = "example-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer_sg.id]
  subnets            = [aws_subnet.example_subnet_1.id, aws_subnet.example_subnet_2.id]
}

resource "aws_ecs_cluster" "example_cluster" {
  name = "example-cluster"
}

resource "aws_launch_configuration" "example_lc" {
  name_prefix                 = "example-lc"
  image_id                    = "ami-0c55b159cbfafe1f0"
  instance_type               = "t2.micro"
  security_groups             = [aws_security_group.ecs_sg.id]
  associate_public_ip_address = false

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "example_asg" {
  name                      = "example-asg"
  vpc_zone_identifier       = [aws_subnet.example_subnet_1.id, aws_subnet.example_subnet_2.id]
  launch_configuration      = aws_launch_configuration.example_lc.name
  min_size                  = 2
  max_size                  = 5
  desired_capacity          = 2
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "example-app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_alb_target_group" "example_tg" {
  name_prefix = "ex-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.example_vpc.id
  health_check {
    path = "/"
  }
}

resource "aws_alb_listener" "example_listener" {
  load_balancer_arn = aws_lb.example_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.example_tg.arn
  }
}

resource "aws_ecs_task_definition" "example_task_definition" {
  family                = "example-task"
  container_definitions = <<DEFINITION
[
{
"name": "example-container",
"image": "node:latest",
"portMappings": [
{
"containerPort": 8080,
"protocol": "tcp"
}
],
"environment": [
{
"name": "DATABASE_URL",
"value": "${aws_db_instance.example_db.endpoint}"
},
{
"name": "CACHE_URL",
"value": "${aws_elasticache_cluster.example_cache.cache_nodes[0].address}"
}
]
}
]
DEFINITION

  cpu                      = "256"
  memory                   = "512"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
}

resource "aws_ecs_service" "example_service" {
  name            = "example-service"
  cluster         = aws_ecs_cluster.example_cluster.id
  task_definition = aws_ecs_task_definition.example_task_definition.arn
  desired_count   = 2
  launch_type     = "EC2"
  network_configuration {
    security_groups = [aws_security_group.ecs_sg.id]
    subnets         = [aws_subnet.example_subnet_1.id, aws_subnet.example_subnet_2.id]
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.example_tg.arn
    container_name   = "example-container"
    container_port   = 8080
  }
}

resource "aws_sns_topic_subscription" "example_subscription" {
  topic_arn = aws_sns_topic.example_topic.arn
  protocol  = "email"
  endpoint  = "example@example.com"
}

output "web-address" {
  value = "http://${aws_lb.example_lb.dns_name}"
}