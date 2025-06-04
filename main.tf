

# By Cesar Armengol June 3rd 2025
# 
# The code deploys:
#	   1. One Application Load Balancer (ALB) that receives inboud connection on port 80. This ALB sits on 2 Public Subnets for High Availability purposes. S
#	      The Security Group only allows traffic on Port 80.
#	   2. The nginxdemo/hello container onto the AWS Fargate service placed on 2 private subnets accepting inbound connections from the ALB.
#	   3. The containers held on Fargate are placed behind the ALB in 2 private subnets to reinforce secuirty and make it HA.



provider "aws" {
  region = "eu-west-1"
}

# This is the VPC that will hold all the resources
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "VPC for the PaloAlto demo"
  }
}

# Here I define all the subnets (2 public and 2 private) using data source to dynamically get available AZs

data "aws_availability_zones" "available" {
  state = "available"
}


resource "aws_subnet" "public" {
  count                   = 2                                     # Deploying 2 PUBLIC subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"    # 10.0.1.0/24, 10.0.2.0/24
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true                                    # This is required for NAT Gateway placement. We need 2 for HA.
  tags = {
    Name = "public-subnet-${data.aws_availability_zones.available.names[count.index]}"
  }
}

resource "aws_subnet" "private" {
  count                   = 2                                       # Deploying 2 PRIVATE subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 101}.0/24"        # 10.0.101.0/24, 10.0.102.0/24
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name = "private-subnet-${data.aws_availability_zones.available.names[count.index]}"
  }
}



# Internet Gateway
resource "aws_internet_gateway" "igw" { # Remember IGWs are "per se" HA, no need to set up 2.
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "PaloAlto-igw"
  }
}

# The Elastic IP address for the NAT
resource "aws_eip" "nat" {
  count  = length(aws_subnet.public) # One EIP for each NAT Gateway
  domain = "vpc"
  tags = {
    Name = "nat-eip-${count.index}"
  }
}

# NAT Gateways (One per Public Subnet for HA)
resource "aws_nat_gateway" "main" {
  count         = length(aws_subnet.public)         # NOTICE: --> One NAT GTW per public subnet to make sure HA comes in properly
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.igw] # Ensure IGW is ready

  tags = {
    Name = "nat-gw-${count.index}"
  }
}

# The Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "PaloAlto-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}


resource "aws_route_table" "private" {
  count  = length(aws_subnet.private)       # Create a dedicated route table for each private SUBNET
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"             # Useful for Operating System patches, etc. Let's connect to the internet via NAT
    nat_gateway_id = aws_nat_gateway.main[count.index].id # Route to the NAT GTW in its respective AZ
  }
  tags = {
    Name = "private-rt-${count.index}"
  }
}


resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}


# Security Group on the ALB. It only accepts inbound connections on Port 80
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP"
  vpc_id      = aws_vpc.main.id

  ingress {
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
    Name = "Security Group for ALB"
  }
}

# Security Group on the ECS (Elastic Container Service). It only accepts inbound connections from the ALB
resource "aws_security_group" "ecs_sg" {
  name        = "ecs-sg"
  description = "Allow ALB to ECS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "Security Group for ECS Tasks"
  }
}

# Application Load Balancer
resource "aws_lb" "alb" {
  name               = "ecs-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id # ALB spans across all public subnets
  tags = {
    Name = "ecs-alb"
  }
}

# Definition for the Target Group
resource "aws_lb_target_group" "tg" {
  name        = "ecs-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path = "/"
    port = "80"
  }
  tags = {
    Name = "ecs-tg"
  }
}

# ALB Listener definition on Port 80
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
  tags = {
    Name = "ecs-listener"
  }
}

# ECS (Elastic Cloud Service) Cluster definition
resource "aws_ecs_cluster" "main" {
  name = "main-cluster"
  tags = {
    Name = "PaloAlto-Cluster"
  }
}

# All the IAM Roles for the Fargate Service
# This role is for Fargate to perform actions on my behalf (e.g., pull image, push logs)
resource "aws_iam_role" "ecs_task_exec_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
  tags = {
    Name = "ecsTaskExecutionRole"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_policy" {
  role       = aws_iam_role.ecs_task_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


# This role is for NGNIX running inside the container
# If your 'nginxdemos/hello' container doesn't need to interact with any AWS services
# (like S3, DynamoDB, etc.), you can either remove the task_role_arn from the task definition
# or leave this role with no attached policies. It's good practice to define it explicitly.

resource "aws_iam_role" "ecs_task_role" {
  name = "ecsTaskRole" # Renamed for clarity vs. exec role

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
  tags = {
    Name = "ecsTaskRole"
  }
}


# ECS Task Definition. This is where I define the Fargate container. Key parameters are:
# 	- CPU 256 means 0.25 vCPU 
# 	- Memory 512MB per task
resource "aws_ecs_task_definition" "app" {
  family                   = "hello-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_exec_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn        # Referencing the newly defined task role
  container_definitions    = jsonencode([
    {
      name        = "hello"
      image       = "nginxdemos/hello"
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ],
      logConfiguration = {                                         # I define the CloudWatch Logs
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/hello-app",
          "awslogs-region"        = "eu-west-1",
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
  tags = {
    Name = "NGINX Hello Taskf"
  }
}


resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/ecs/hello-app" # Log group for your Fargate tasks
  retention_in_days = 7 # Adjust as needed
  tags = {
    Name = "NGINX-logs"
  }
}


# The Service definition within the ECS Cluster. Notice we define a serverless architecture as the service will use AWS FARGATE (Serverless). 
# The service is deployed in Private Subnets.
resource "aws_ecs_service" "app" {
  name            = "hello-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"
  desired_count   = 2
  network_configuration {
    subnets          = aws_subnet.private[*].id          # Fargate tasks will run in private subnets, spanning both AZs
    assign_public_ip = false
    security_groups  = [aws_security_group.ecs_sg.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "hello"
    container_port   = 80
  }
  deployment_controller {
    type = "ECS"
  }

  # Ensure the service waits for the listener and NAT Gateways to be fully provisioned
  depends_on = [
    aws_lb_listener.listener,
    aws_nat_gateway.main # Critical for Fargate to pull images from ECR if not public, and for outbound connectivity
  ]
  tags = {
    Name = "hello-service"
  }
}

# 
output "alb_dns_name" {
  description = "The DNS name of the ALB."
  value       = aws_lb.alb.dns_name
}
