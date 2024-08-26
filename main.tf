terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  backend "s3" {
    bucket         	   = "nemac-terraform"
    key              	   = "state/terraform.tfstate"
    region         	   = "us-east-1"
    encrypt        	   = true
    dynamodb_table = "nemac-terraform"
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_ecr_repository" "app_ecr_repo" {
  name = "camptocamp/mapserver"
}

resource "aws_ecs_cluster" "my_cluster" {
  name = "mapserver"
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name = "/ecs/mapserver"
}

resource "aws_ecs_task_definition" "app_task" {
  family                   = "app-first-task" # Name your task
  requires_compatibilities = ["FARGATE"] # use Fargate as the launch type
  network_mode             = "awsvpc"    # add the AWS VPN network mode as this is required for Fargate
  memory                   = 512         # Specify the memory the container requires
  cpu                      = 256         # Specify the CPU the container requires
  execution_role_arn       = "${aws_iam_role.ecsTaskExecutionRole.arn}"

  volume {
    name = "NEMAC"

    efs_volume_configuration {
      file_system_id = "fs-e1950214"
      root_directory = "/" # Specify if you want to use a subdirectory of your EFS file system
    }
  }

  container_definitions = jsonencode(
  [
    {
      "name": "app-first-task",
      "image": "${aws_ecr_repository.app_ecr_repo.repository_url}",
      "essential": true,
      mountPoints = [
        {
          sourceVolume  = "NEMAC"
          containerPath = "/etc/mapserver"
          readOnly      = false
        },
      ],
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80
        }
      ],
      "memory": 512,
      "cpu": 256,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${aws_cloudwatch_log_group.ecs_logs.name}",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ])
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Provide a reference to your default VPC
resource "aws_vpc" "default" {
  cidr_block = "172.30.0.0/16"
  tags = {
    Name = "default"
  }
}

# Provide references to your default subnets
resource "aws_subnet" "default_subnet_a" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "172.30.0.0/24"
  map_public_ip_on_launch = true
  availability_zone = "us-east-1a"
  tags = {
    Name = "default_subnet_a"
  }
}

resource "aws_subnet" "default_subnet_b" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "172.30.1.0/24"
  map_public_ip_on_launch = true
  availability_zone = "us-east-1b"
  tags = {
    Name = "default_subnet_b"
  }
}

resource "aws_subnet" "default_subnet_c" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "172.30.2.0/24"
  map_public_ip_on_launch = true
  availability_zone = "us-east-1c"
  tags = {
    Name = "default_subnet_c"
  }
}

resource "aws_alb" "application_load_balancer" {
  name               = "load-balancer-dev" #load balancer name
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    "${aws_subnet.default_subnet_a.id}",
    "${aws_subnet.default_subnet_b.id}",
    "${aws_subnet.default_subnet_c.id}"
  ]
  # security group
  security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
}

# Create a security group for the load balancer:
resource "aws_security_group" "load_balancer_security_group" {
  vpc_id = "${aws_vpc.default.id}"
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow traffic in from all sources
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "target_group" {
  name        = "target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "${aws_vpc.default.id}" # default VPC
  health_check {
    enabled             = true
    interval            = 300 # Time between health checks in seconds
    path                = "/server-status-remote" # Adjust if your application responds to a different path
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5 # Response timeout in seconds
    matcher             = "200-399" # Consider 2xx and 3xx HTTP status codes as healthy
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = "${aws_alb.application_load_balancer.arn}" #  load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.target_group.arn}" # target group
  }
}

resource "aws_ecs_service" "app_service" {
  name            = "mapserver-app"     # Name the service
  cluster         = "${aws_ecs_cluster.my_cluster.id}"   # Reference the created Cluster
  task_definition = "${aws_ecs_task_definition.app_task.arn}" # Reference the task that the service will spin up
  launch_type     = "FARGATE"
  desired_count   = 1 # Set up the number of containers to 1

  load_balancer {
    target_group_arn = "${aws_lb_target_group.target_group.arn}" # Reference the target group
    container_name   = "${aws_ecs_task_definition.app_task.family}"
    container_port   = 80 # Specify the container port
  }

  network_configuration {
    subnets          = ["${aws_subnet.default_subnet_a.id}", "${aws_subnet.default_subnet_b.id}", "${aws_subnet.default_subnet_c.id}"]
    assign_public_ip = true     # Provide the containers with public IPs
    security_groups  = ["${aws_security_group.service_security_group.id}"] # Set up the security group
  }
}

resource "aws_security_group" "service_security_group" {
  vpc_id = "${aws_vpc.default.id}"
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Only allowing traffic in from the load balancer security group
    security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
