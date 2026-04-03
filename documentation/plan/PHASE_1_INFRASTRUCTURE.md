# KubeQuest — Infrastructure Setup
> Terraform + AWS | Phase 1

---

## Overview

Since no infrastructure is provided, you need to provision it yourself on AWS using Terraform.
This guide walks you through setting up all 4 VMs from scratch.

### Machines to provision
| Name | Role | Instance Type |
|------|------|--------------|
| `kube-1` | Kubernetes control plane + worker | t3.medium |
| `kube-2` | Kubernetes worker | t3.medium |
| `ingress` | Ingress controller, external traffic | t3.small |
| `monitoring` | Prometheus, Grafana, Loki | t3.large |

---

## Prerequisites

Install these tools locally before starting:

```bash
# Terraform
brew install terraform       # macOS
sudo apt install terraform   # Ubuntu

# AWS CLI
brew install awscli

# Configure AWS credentials
aws configure
# You will be prompted for:
# - AWS Access Key ID
# - AWS Secret Access Key
# - Default region (e.g. eu-west-1)
# - Default output format (json)
```

---

## Project Structure

```
terraform/
├── main.tf          # EC2 instances
├── network.tf       # VPC, subnets, security groups
├── variables.tf     # All configurable values
├── outputs.tf       # Public IPs, instance IDs
├── backend.tf       # Remote state on S3
└── keys/
    └── kubequest.pub  # Your SSH public key
```

---

## Step 1 — Generate SSH Key

```bash
mkdir -p terraform/keys
ssh-keygen -t ed25519 -f terraform/keys/kubequest -C "kubequest"
# This creates:
# terraform/keys/kubequest      → private key (keep this locally, never commit)
# terraform/keys/kubequest.pub  → public key (used by Terraform)
```

> Add `terraform/keys/kubequest` to your `.gitignore` — never push private keys.

---

## Step 2 — Remote State (S3 Backend)

Create an S3 bucket manually in the AWS console first, then configure the backend:

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket = "kubequest-tfstate"
    key    = "prod/terraform.tfstate"
    region = "eu-west-1"
  }
}
```

---

## Step 3 — Network

```hcl
# network.tf
resource "aws_vpc" "kubequest" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "kubequest-vpc" }
}

resource "aws_subnet" "kubequest" {
  vpc_id                  = aws_vpc.kubequest.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags = { Name = "kubequest-subnet" }
}

resource "aws_internet_gateway" "kubequest" {
  vpc_id = aws_vpc.kubequest.id
}

resource "aws_route_table" "kubequest" {
  vpc_id = aws_vpc.kubequest.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.kubequest.id
  }
}

resource "aws_route_table_association" "kubequest" {
  subnet_id      = aws_subnet.kubequest.id
  route_table_id = aws_route_table.kubequest.id
}

resource "aws_security_group" "kubequest" {
  name   = "kubequest-sg"
  vpc_id = aws_vpc.kubequest.id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all internal traffic between nodes
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

---

## Step 4 — EC2 Instances

```hcl
# main.tf
resource "aws_key_pair" "kubequest" {
  key_name   = "kubequest-key"
  public_key = file("${path.module}/keys/kubequest.pub")
}

locals {
  instances = {
    kube-1     = { type = "t3.medium" }
    kube-2     = { type = "t3.medium" }
    ingress    = { type = "t3.small"  }
    monitoring = { type = "t3.large"  }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "kubequest" {
  for_each = local.instances

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = each.value.type
  subnet_id              = aws_subnet.kubequest.id
  vpc_security_group_ids = [aws_security_group.kubequest.id]
  key_name               = aws_key_pair.kubequest.key_name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name    = each.key
    Project = "kubequest"
  }
}
```

---

## Step 5 — Outputs

```hcl
# outputs.tf
output "instance_ips" {
  value = {
    for name, instance in aws_instance.kubequest :
    name => instance.public_ip
  }
}
```

---

## Step 6 — Variables (optional but recommended)

```hcl
# variables.tf
variable "aws_region" {
  default = "eu-west-1"
}

variable "project" {
  default = "kubequest"
}
```

---

## Step 7 — Deploy

```bash
cd terraform/

# Initialize Terraform (downloads providers, connects to S3 backend)
terraform init

# Preview what will be created
terraform plan

# Provision everything
terraform apply

# Get your public IPs
terraform output instance_ips
```

Expected output:
```
instance_ips = {
  "ingress"    = "x.x.x.x"
  "kube-1"     = "x.x.x.x"
  "kube-2"     = "x.x.x.x"
  "monitoring" = "x.x.x.x"
}
```

---

## Step 8 — Verify SSH Access

```bash
ssh -i terraform/keys/kubequest ubuntu@<kube-1-ip>
ssh -i terraform/keys/kubequest ubuntu@<kube-2-ip>
ssh -i terraform/keys/kubequest ubuntu@<ingress-ip>
ssh -i terraform/keys/kubequest ubuntu@<monitoring-ip>
```

All 4 machines should be reachable before proceeding.

---

## Tear Down

```bash
# Destroy all resources when done
terraform destroy
```

> VMs are automatically shut down every evening on AWS to save costs.
> You can restart them at any time from the AWS console or with Terraform.

---

## .gitignore

Make sure your repo has these entries:

```
terraform/keys/kubequest
terraform/.terraform/
terraform/terraform.tfstate
terraform/terraform.tfstate.backup
*.tfvars
```

---

## Next Step

Once all 4 VMs are up and SSH access is confirmed, proceed to:
**[Phase 2 — Kubernetes Cluster Bootstrap](./CLUSTER_BOOTSTRAP.md)**