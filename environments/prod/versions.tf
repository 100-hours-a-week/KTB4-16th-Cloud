terraform {
  required_version = ">= 1.10, < 2.0"
  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    aws = {
      source = "hashicorp/aws", version = "~> 6.0"
    }
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.config.account_id]
  default_tags {
    tags = {
      Project = "mulo", Version = "v3", Environment = "prod", ManagedBy = "terraform"
    }
  }
}

