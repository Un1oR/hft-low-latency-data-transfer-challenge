terraform {
  required_version = ">= 1.15.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.55"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
