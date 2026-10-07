/*
 * 개발 서버다 (INF-45, docs/system-design/런치캐치_개발서버.md).
 * 운영(terraform/)과 상태를 나눠 따로 올리고 내린다. 운영을 destroy 해도 이것은 남는다.
 */

terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket, key, region 은 backend.hcl 로 넘긴다. 잠금은 S3 네이티브다.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile != "" ? var.aws_profile : null

  # 운영과 같은 장치다. 다른 계정 자격증명이면 plan 에서 멈춘다.
  allowed_account_ids = var.allowed_account_ids

  # Env 로 운영 리소스와 가른다. 운영 스크립트는 Role 태그로 찾으므로 섞이지 않는다.
  default_tags {
    tags = {
      Project   = var.project
      Env       = "dev"
      ManagedBy = "terraform"
    }
  }
}
