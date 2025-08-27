# main.tf

# 1. Specify the AWS provider and region
provider "aws" {
  region = "us-east-1" # Make sure this matches the region you used in `aws configure`
}

# 2. Create a VPC (Your own virtual network)
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16" # A large range of private IP addresses
  tags = {
    Name = "SecureHost-VPC"
  }
}

# 3. Create an Internet Gateway (The door to the internet for your VPC)
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id # This attaches it to your VPC

  tags = {
    Name = "SecureHost-IGW"
  }
}

# 4. Create an IAM Role for the EC2 instance
resource "aws_iam_role" "ec2_role" {
  name = "XinYi-EC2" # You can change this, but it's a good name

  # This defines who can assume this role. In this case, the EC2 service.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    Name = "SecureHost-EC2-Role"
  }
}

# 5. Attach the AWS Managed Policy for SSM to the Role
resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 6. Create an Instance Profile to attach the Role to the EC2 instance
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "XINYIEC2-Profile"
  role = aws_iam_role.ec2_role.name
}

# 7. Create a Public Subnet (A slice of your VPC in one data center)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24" # A smaller range inside the VPC
  availability_zone       = "us-east-1a"  # Pick an AZ in your region
  map_public_ip_on_launch = true          # This makes it a *public* subnet

  tags = {
    Name = "SecureHost-Public-Subnet"
  }
}

# 8. Create a Route Table for the Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  # This rule sends all internet-bound traffic (0.0.0.0/0) to the Internet Gateway
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "SecureHost-Public-RT"
  }
}

# 9. Associate the Route Table with the Public Subnet
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 10. Create a Security Group for the Web Server (REPLACES the old one)
resource "aws_security_group" "web_sg" {
  name        = "web-server-sg"
  description = "Allow HTTP/HTTPS from internet and SSH from my IP. Allow outbound to DB SG."
  vpc_id      = aws_vpc.main.id

  # Allow HTTP/HTTPS from the world
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  # Allow inbound HTTPS from the world AND SSM traffic from AWS
  ingress {
    description = "Allow HTTPS for web traffic and SSM for management"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ALL outbound traffic (the web server needs to talk to the internet and the database)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Web-Server-SG"
  }
}

# 11. Create a Security Group for the Database
resource "aws_security_group" "db_sg" {
  name        = "database-sg"
  description = "Allow inbound PostgreSQL traffic ONLY from the Web Server SG"
  vpc_id      = aws_vpc.main.id

  # ONLY allow port 5432 (PostgreSQL) from resources that have the Web Server SG attached.
  # This is the most secure method. It doesn't use IP addresses, it uses the SG ID.
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id] # <- This is the key line
  }

  # Allow the database to make outbound requests (e.g., for updates)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Database-SG"
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_security_group.web_sg
  ]
}

# 12. FINALLY: Launch your EC2 Instance
resource "aws_instance" "web_server" {
  ami           = "ami-0fc5d935ebf8bc3bc" # Amazon Linux 2023 AMI in us-east-1
  instance_type = "t3.micro"              # Free tier eligible
  subnet_id     = aws_subnet.public.id    # Launch it in our public subnet

  # Attach the IAM Instance Profile (which has the SSM permission)
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  # Attach the Security Group
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  tags = {
    Name = "XinYi-Web-Server"
  }

  # The 'user_data' script can be used to install software on first boot.
  # For example, to install a web server:
  user_data = <<-EOF
              #!/bin/bash
              sudo dnf update -y
              sudo dnf install -y nginx
              sudo systemctl start nginx
              sudo systemctl enable nginx
              EOF
}

# 13. Create a PRIVATE Subnet (for the database)
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"    # Different CIDR block than the public subnet
  availability_zone = "us-east-1a"     # Often best practice to use the same AZ for low-latency
  # DO NOT enable map_public_ip_on_launch. This keeps it private.

  tags = {
    Name = "SecureHost-Private-Subnet"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "SecureHost-Private-Subnet-B"
  }
}

# 14. Allocate an Elastic IP for the NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc" # This EIP will be used in a VPC

  tags = {
    Name = "SecureHost-NAT-EIP"
  }
}

# 15. Create a NAT Gateway in the PUBLIC subnet
resource "aws_nat_gateway" "gw" {
  allocation_id = aws_eip.nat.id       # Attach the Elastic IP
  subnet_id     = aws_subnet.public.id # Place it in the public subnet

  tags = {
    Name = "SecureHost-NAT-GW"
  }

  # To ensure proper ordering, it's good to say the NAT Gateway depends on the IGW
  depends_on = [aws_internet_gateway.gw]
}

# 16. Create a Route Table for the PRIVATE Subnet
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # This rule sends all internet-bound traffic (0.0.0.0/0) to the NAT Gateway
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.gw.id
  }

  tags = {
    Name = "SecureHost-Private-RT"
  }
}

# 17. Associate the Private Route Table with the Private Subnet
resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_assoc_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# 19. Create a DB Subnet Group (RDS needs this to know which subnets it can use)
resource "aws_db_subnet_group" "main" {
  name       = "securehost-main"
  subnet_ids = [aws_subnet.private.id, aws_subnet.private_b.id] # You can add a second subnet in another AZ for High Availability later.

  tags = {
    Name = "SecureHost-DB-Subnet-Group"
  }
}

# 20. Create the PostgreSQL Database Instance
resource "aws_db_instance" "main" {
  identifier             = "securehostdb"
  instance_class         = "db.t3.micro" # Free tier eligible
  allocated_storage      = 20            # GB, min for free tier
  engine                 = "postgres"
  engine_version         = "15"          # Use a recent stable version
  username               = "XinYi"    # Change this to a custom admin username in a real project!
  password               = "YourSuperSecurePassword123!" # Change this! Use a Terraform variable for secrets.
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  publicly_accessible    = false         # THIS IS CRITICAL! Must be false.
  skip_final_snapshot    = true          # Allows you to run 'terraform destroy' without issues. Set to 'false' for production.

  tags = {
    Name = "SecureHost-Database"
  }

  depends_on = [
    aws_db_subnet_group.main,
    aws_security_group.db_sg
  ]
}