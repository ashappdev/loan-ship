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

resource "aws_ecr_repository" "app_ecr_repo" {
  name = "example_app"
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

resource "aws_db_subnet_group" "example_db_subnet_group" {
  name       = "example_db_subnet_group"
  subnet_ids = [aws_subnet.example_subnet_1.id, aws_subnet.example_subnet_2.id]
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
      "image": "${aws_ecr_repository.app_ecr_repo.repository_url}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 80
        }
      ],
      "memory": 512,
      "cpu": 256
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

output "web-address" {
  value = "http://${aws_lb.example_lb.dns_name}"
}