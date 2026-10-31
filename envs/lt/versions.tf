/*
 * 부하 시험 환경이다. 운영과 같은 모듈을 쓰고 차이는 main.tf 에서 값으로만 준다.
 * scripts/member-env.sh 가 계정마다 상태 버킷과 변수 파일을 정해 이 루트를 그대로 돌린다.
 */

terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  /*
   * bucket, key, region 은 member-env.sh 가 -backend-config 로 넘긴다.
   * 계정마다 버킷이 다르다.
   */
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

# 자격증명은 member-env.sh 를 부른 사람의 AWS_PROFILE 을 그대로 쓴다.
provider "aws" {
  region = var.region

  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

/*
 * edge 와 observability 모듈이 요구한다.
 * 도메인이 없어 이 리전에 만들어지는 것은 없다.
 */
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
